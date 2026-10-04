using System.Numerics;
using Clio.Editor;
using Clio.Editor.Markdown;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using Windows.UI;

namespace Clio.App;

/// <summary>
/// Custom DirectWrite editor surface over <see cref="EditorModel"/>: wrapped text, caret and selection,
/// keyboard and mouse editing, focus dimming, typewriter scrolling and a line minimap.
/// Still open from the phase 3 acceptance list: source-preserving highlighting, IME composition
/// (CoreTextEditContext), UI Automation text provider, slash commands, high contrast.
/// </summary>
public sealed class EditorControl : UserControl
{
    private const float TextSize = 17;
    private const float LineHeight = TextSize * 1.65f;
    private const double MaxColumn = 760;
    private const double SideMargin = 48;
    private const double MinimapWidth = 28;
    private const double DoubleClickMs = 500;

    private static readonly Color TextColor = EditorStyler.Foreground;
    private static readonly Color DimColor = EditorStyler.Dimmed;
    private static readonly Color SelectionColor = Color.FromArgb(255, 0x1F, 0x29, 0x37);
    private static readonly Color CaretColor = Color.FromArgb(255, 0x39, 0x8A, 0xB0);

    private readonly CanvasControl _canvas = new() { ClearColor = Color.FromArgb(255, 0, 0, 0) };
    private readonly DispatcherTimer _blink = new() { Interval = TimeSpan.FromMilliseconds(530) };
    private readonly DispatcherTimer _ease = new() { Interval = TimeSpan.FromMilliseconds(16) };

    private CanvasTextLayout? _layout;
    private double _layoutWidth;
    private double _scroll;
    private double _desiredX = -1;
    private bool _caretOn = true;
    private bool _manualScroll;
    private bool _dragging;
    private int _clicks;
    private DateTime _lastClick;
    private char _pendingHighSurrogate;
    private LineMinimap _minimap = LineMinimap.Empty;
    private IReadOnlyList<MarkdownSpan> _spans = [];
    private CancellationTokenSource? _highlightCts;
    private int _highlightVersion;
    private const int HighlightDebounceMs = 80;
    private double _easeStart, _easeTarget;
    private DateTime _easeBegan;

    public EditorModel Model { get; private set; }

    public bool FocusMode { get; set => Set(ref field, value); }
    public bool TypewriterMode { get; set => Set(ref field, value); }
    public double TypewriterAnchor { get; set => Set(ref field, TypewriterMath.ResolveAnchor(value)); } = TypewriterMath.DefaultAnchor;

    /// <summary>Raised after the buffer content changes through user editing or <see cref="SetText"/>.</summary>
    public event Action? TextChanged;

    public string Text => Model.Buffer.Text;

    public EditorControl()
    {
        Model = Attach(new EditorModel(new TextBuffer()));
        IsTabStop = true;
        Content = _canvas;
        _canvas.Draw += OnDraw;
        _canvas.SizeChanged += (_, _) => { _layout = null; _canvas.Invalidate(); };
        Unloaded += (_, _) => _canvas.RemoveFromVisualTree();
        _canvas.PointerPressed += OnPointerPressed;
        _canvas.PointerMoved += OnPointerMoved;
        _canvas.PointerReleased += (_, e) => { _dragging = false; _canvas.ReleasePointerCapture(e.Pointer); };
        _canvas.PointerWheelChanged += OnWheel;
        _blink.Tick += (_, _) => { _caretOn = !_caretOn; _canvas.Invalidate(); };
        _ease.Tick += OnEaseTick;
        GotFocus += (_, _) => { _blink.Start(); ResetCaret(); };
        LostFocus += (_, _) => { _blink.Stop(); _caretOn = false; _canvas.Invalidate(); };
        KeyDown += OnKeyDown;
        CharacterReceived += OnCharacterReceived;
    }

    /// <summary>Replace the document. Clears undo history and does not raise <see cref="TextChanged"/>.</summary>
    public void SetText(string text)
    {
        Model.Buffer.Reset(text);
        Model.SetSelection(0, 0);
        _scroll = 0;
        _layout = null;
        _minimap = LineMinimap.Make(text);
        _spans = [];
        ScheduleHighlight();
        _canvas.Invalidate();
    }

    private EditorModel Attach(EditorModel model)
    {
        model.Buffer.Changed += change =>
        {
            _layout = null;
            _minimap = LineMinimap.Make(model.Buffer.Text);
            _spans = ShiftSpans(_spans, change);
            ScheduleHighlight();
            TextChanged?.Invoke();
        };
        model.SelectionChanged += OnSelectionChanged;
        return model;
    }

    // ---- highlighting ---------------------------------------------------------------------------

    /// <summary>
    /// Keeps the previous styling roughly in place while a fresh pass runs: spans before the edit stay,
    /// spans after it move by the length delta, spans the edit touches are dropped.
    /// </summary>
    private static IReadOnlyList<MarkdownSpan> ShiftSpans(IReadOnlyList<MarkdownSpan> spans, TextChange change)
    {
        if (spans.Count == 0) return spans;
        var removedEnd = change.Start + change.Removed.Length;
        var delta = change.Inserted.Length - change.Removed.Length;
        var shifted = new List<MarkdownSpan>(spans.Count);
        foreach (var s in spans)
        {
            if (s.End <= change.Start) shifted.Add(s);
            else if (s.Start >= removedEnd) shifted.Add(s with { Start = s.Start + delta });
        }
        return shifted;
    }

    private void ScheduleHighlight()
    {
        _highlightCts?.Cancel();
        var cts = _highlightCts = new CancellationTokenSource();
        var version = ++_highlightVersion;
        var text = Model.Buffer.Text;
        var queue = DispatcherQueue;
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(HighlightDebounceMs, cts.Token);
                var bytes = text.Length > 3_000_000 ? System.Text.Encoding.UTF8.GetByteCount(text) : text.Length;
                var spans = MarkdownHighlighter.Highlight(text, MarkdownHighlighter.ModeFor(bytes), cts.Token);
                queue.TryEnqueue(() =>
                {
                    if (version != _highlightVersion) return;
                    _spans = spans;
                    _layout = null;
                    _canvas.Invalidate();
                });
            }
            catch (OperationCanceledException) { }
        });
    }

    private void Set(ref bool field, bool value)
    {
        if (field == value) return;
        field = value;
        _layout = null;
        if (TypewriterMode) RevealCaret(snap: true);
        _canvas.Invalidate();
    }

    private void Set(ref double field, double value)
    {
        field = value;
        _canvas.Invalidate();
    }

    // ---- layout ---------------------------------------------------------------------------------

    private double ColumnWidth => Math.Max(120, Math.Min(MaxColumn, _canvas.ActualWidth - 2 * SideMargin - MinimapWidth));
    private double Left => Math.Max(SideMargin, (_canvas.ActualWidth - MinimapWidth - ColumnWidth) / 2);
    private double DocPadding => TypewriterMath.DocumentPadding(_canvas.ActualHeight, TypewriterAnchor, TypewriterMode);

    private CanvasTextLayout EnsureLayout()
    {
        var width = ColumnWidth;
        if (_layout is not null && Math.Abs(_layoutWidth - width) < 0.5) return _layout;
        var format = new CanvasTextFormat
        {
            FontFamily = "ms-appx:///Assets/Fonts/#Hack",
            FontSize = TextSize,
            WordWrapping = CanvasWordWrapping.Wrap,
            LineSpacing = LineHeight,
            LineSpacingBaseline = LineHeight * 0.8f,
        };
        _layout = new CanvasTextLayout(_canvas, Model.Buffer.Text, format, (float)width, float.MaxValue);
        _layoutWidth = width;
        RestyleLayout();
        return _layout;
    }

    /// <summary>Base colour, then Markdown styling, then focus dimming outside the focus unit.</summary>
    private void RestyleLayout()
    {
        if (_layout is null) return;
        var length = Model.Buffer.Length;
        if (length == 0) return;
        _layout.SetColor(0, length, TextColor);
        EditorStyler.Apply(_layout, _spans, length, TextSize);
        if (!FocusMode) return;
        // A null range (blank line) dims nothing: see commit 1a08c6b.
        if (FocusUnit.FocusRange(Model.Buffer.Text, Model.Selection) is not { } focus) return;
        // Dim only outside the focus unit so highlighting inside it stays intact.
        var focusStart = Math.Clamp(focus.Start, 0, length);
        var focusEnd = Math.Clamp(focus.End, focusStart, length);
        if (focusStart > 0) _layout.SetColor(0, focusStart, DimColor);
        if (focusEnd < length) _layout.SetColor(focusEnd, length - focusEnd, DimColor);
    }

    private double DocumentHeight => EnsureLayout().LayoutBounds.Height + 2 * DocPadding;

    private Windows.Foundation.Rect CaretRect(int offset)
    {
        var layout = EnsureLayout();
        var text = Model.Buffer.Text;
        if (offset >= text.Length && text.EndsWith('\n'))
        {
            // DirectWrite reports the end of the previous line; the caret belongs on the empty last line.
            var last = text.Length == 1 ? Vector2.Zero : layout.GetCaretPosition(text.Length - 1, false);
            return new Windows.Foundation.Rect(0, last.Y + LineHeight, 1, LineHeight);
        }
        var pos = layout.GetCaretPosition(offset, false);
        return new Windows.Foundation.Rect(pos.X, pos.Y, 1, LineHeight);
    }

    // ---- drawing --------------------------------------------------------------------------------

    private void OnDraw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        var ds = args.DrawingSession;
        var layout = EnsureLayout();
        _scroll = ClampScroll(_scroll);
        var origin = new Vector2((float)Left, (float)(DocPadding - _scroll));

        if (Model.HasSelection)
        {
            var sel = Model.Selection;
            foreach (var region in layout.GetCharacterRegions(sel.Start, sel.Length))
            {
                var b = region.LayoutBounds;
                ds.FillRectangle((float)(origin.X + b.X), (float)(origin.Y + b.Y), (float)Math.Max(b.Width, 4), (float)b.Height, SelectionColor);
            }
        }

        ds.DrawTextLayout(layout, origin, TextColor);

        if (_caretOn && !Model.HasSelection && FocusState != FocusState.Unfocused)
        {
            var c = CaretRect(Model.Caret);
            var x = (float)(origin.X + c.X);
            ds.DrawLine(x, (float)(origin.Y + c.Y), x, (float)(origin.Y + c.Y + c.Height), CaretColor, 1.5f);
        }

        DrawMinimap(ds);
    }

    private void DrawMinimap(CanvasDrawingSession ds)
    {
        var strokes = _minimap.Displayed(_canvas.ActualHeight);
        if (strokes.Count == 0) return;
        var active = _minimap.ActiveIndex(Model.Caret);
        var activeStroke = _minimap.Strokes.Count > active ? _minimap.Strokes[active] : default;
        var pitch = 8.0;
        var top = Math.Max(16, (_canvas.ActualHeight - strokes.Count * pitch) / 2);
        var right = _canvas.ActualWidth - 8;
        for (var i = 0; i < strokes.Count; i++)
        {
            var w = (float)(4 + strokes[i].Width * (MinimapWidth - 8));
            var isActive = strokes[i].Offset == activeStroke.Offset ||
                           (i + 1 < strokes.Count ? strokes[i].Offset <= Model.Caret && Model.Caret < strokes[i + 1].Offset : strokes[i].Offset <= Model.Caret);
            var color = isActive ? Color.FromArgb(255, 0xEB, 0xEB, 0xEB) : Color.FromArgb(110, 0xA0, 0xA0, 0xA0);
            ds.FillRoundedRectangle((float)(right - w), (float)(top + i * pitch), w, 2.5f, 1.25f, 1.25f, color);
        }
    }

    // ---- scrolling ------------------------------------------------------------------------------

    private double ClampScroll(double value) => Math.Clamp(value, 0, Math.Max(0, DocumentHeight - _canvas.ActualHeight));

    private void OnSelectionChanged()
    {
        if (FocusMode) RestyleLayout();
        ResetCaret();
        RevealCaret(snap: !_manualScroll);
    }

    private void RevealCaret(bool snap)
    {
        var rect = CaretRect(Model.Caret);
        var viewport = _canvas.ActualHeight;
        if (viewport <= 0) return;
        var top = DocPadding + rect.Y;
        double target;
        if (TypewriterMode)
        {
            target = TypewriterMath.TargetScrollOffset(top, rect.Height, viewport, TypewriterAnchor, DocumentHeight);
        }
        else
        {
            target = _scroll;
            if (top < _scroll + 24) target = top - 24;
            else if (top + rect.Height > _scroll + viewport - 24) target = top + rect.Height - viewport + 24;
            target = ClampScroll(target);
        }
        _manualScroll = false;
        if (snap || !TypewriterMode) { _ease.Stop(); _scroll = target; }
        else { _easeStart = _scroll; _easeTarget = target; _easeBegan = DateTime.UtcNow; _ease.Start(); }
        _canvas.Invalidate();
    }

    private void OnEaseTick(object? sender, object e)
    {
        var elapsed = DateTime.UtcNow - _easeBegan;
        _scroll = TypewriterMath.EaseReturn(_easeStart, _easeTarget, elapsed);
        if (elapsed >= TypewriterMath.ReturnDuration) _ease.Stop();
        _canvas.Invalidate();
    }

    private void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        var delta = e.GetCurrentPoint(_canvas).Properties.MouseWheelDelta;
        _ease.Stop();
        _manualScroll = true;
        _scroll = ClampScroll(_scroll - delta);
        _canvas.Invalidate();
        e.Handled = true;
    }

    private void ResetCaret()
    {
        _caretOn = true;
        _blink.Stop();
        _blink.Start();
        _canvas.Invalidate();
    }

    // ---- pointer --------------------------------------------------------------------------------

    private int HitOffset(Windows.Foundation.Point p)
    {
        var layout = EnsureLayout();
        var x = (float)(p.X - Left);
        var y = (float)(p.Y - DocPadding + _scroll);
        layout.HitTest(x, y, out var region, out bool isTrailing);
        var index = isTrailing ? region.CharacterIndex + region.CharacterCount : region.CharacterIndex;
        return Math.Clamp(index, 0, Model.Buffer.Length);
    }

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        Focus(FocusState.Pointer);
        var point = e.GetCurrentPoint(_canvas);
        if (!point.Properties.IsLeftButtonPressed) return;
        var offset = HitOffset(point.Position);
        var shift = e.KeyModifiers.HasFlag(VirtualKeyModifiers.Shift);
        var now = DateTime.UtcNow;
        _clicks = (now - _lastClick).TotalMilliseconds < DoubleClickMs ? _clicks + 1 : 1;
        _lastClick = now;
        _desiredX = -1;
        _manualScroll = false;

        if (_clicks == 2)
        {
            var word = Model.WordAt(offset);
            Model.SetSelection(word.Start, word.End);
        }
        else if (_clicks >= 3)
        {
            var line = Model.Buffer.LineOf(offset);
            var end = line + 1 < Model.Buffer.LineCount ? Model.Buffer.LineStart(line + 1) : Model.Buffer.Length;
            Model.SetSelection(Model.Buffer.LineStart(line), end);
        }
        else if (shift) Model.MoveCaret(offset, extend: true);
        else Model.SetSelection(offset, offset);

        _dragging = _clicks == 1;
        _canvas.CapturePointer(e.Pointer);
        e.Handled = true;
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging) return;
        Model.MoveCaret(HitOffset(e.GetCurrentPoint(_canvas).Position), extend: true);
    }

    // ---- keyboard -------------------------------------------------------------------------------

    private static bool Down(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var ctrl = Down(VirtualKey.Control);
        var shift = Down(VirtualKey.Shift);
        var handled = true;
        var vertical = false;
        switch (e.Key)
        {
            case VirtualKey.Left: if (ctrl) Model.MoveWordLeft(shift); else Model.MoveLeft(shift); break;
            case VirtualKey.Right: if (ctrl) Model.MoveWordRight(shift); else Model.MoveRight(shift); break;
            case VirtualKey.Up: MoveVertical(-1, shift); vertical = true; break;
            case VirtualKey.Down: MoveVertical(1, shift); vertical = true; break;
            case VirtualKey.PageUp: MoveVertical(-Math.Max(1, (int)(_canvas.ActualHeight / (TextSize * 1.65)) - 2), shift); vertical = true; break;
            case VirtualKey.PageDown: MoveVertical(Math.Max(1, (int)(_canvas.ActualHeight / (TextSize * 1.65)) - 2), shift); vertical = true; break;
            case VirtualKey.Home: if (ctrl) Model.MoveToDocumentStart(shift); else MoveToVisualLineEdge(start: true, shift); break;
            case VirtualKey.End: if (ctrl) Model.MoveToDocumentEnd(shift); else MoveToVisualLineEdge(start: false, shift); break;
            case VirtualKey.Back: if (ctrl) Model.DeleteWordBackward(); else Model.Backspace(); break;
            case VirtualKey.Delete: Model.DeleteForward(); break;
            case VirtualKey.Enter: Model.Insert("\n"); break;
            case VirtualKey.Tab: Model.Insert("    "); break;
            case VirtualKey.A when ctrl: Model.SelectAll(); break;
            case VirtualKey.Z when ctrl && shift: Model.Redo(); break;
            case VirtualKey.Z when ctrl: Model.Undo(); break;
            case VirtualKey.Y when ctrl: Model.Redo(); break;
            case VirtualKey.C when ctrl: Copy(cut: false); break;
            case VirtualKey.X when ctrl: Copy(cut: true); break;
            case VirtualKey.V when ctrl: _ = PasteAsync(); break;
            default: handled = false; break;
        }
        if (!vertical) _desiredX = -1;
        e.Handled = handled;
    }

    private void OnCharacterReceived(UIElement sender, CharacterReceivedRoutedEventArgs e)
    {
        var ch = e.Character;
        // Control characters arrive here too; Enter/Tab/Back are handled in KeyDown, shortcuts must not type.
        if (char.IsControl(ch)) return;
        if (Down(VirtualKey.Control) && !Down(VirtualKey.Menu)) return;
        if (char.IsHighSurrogate(ch)) { _pendingHighSurrogate = ch; e.Handled = true; return; }
        var text = char.IsLowSurrogate(ch) && _pendingHighSurrogate != 0 ? $"{_pendingHighSurrogate}{ch}" : ch.ToString();
        _pendingHighSurrogate = '\0';
        Model.Insert(text, typing: true, nowMs: Environment.TickCount64);
        _desiredX = -1;
        e.Handled = true;
    }

    private void MoveVertical(int lines, bool extend)
    {
        var layout = EnsureLayout();
        var rect = CaretRect(Model.Caret);
        if (_desiredX < 0) _desiredX = rect.X;
        var metrics = layout.LineMetrics;
        var lineHeight = metrics.Length > 0 ? metrics[0].Height : TextSize * 1.65;
        var y = rect.Y + rect.Height / 2 + lines * lineHeight;
        var docHeight = layout.LayoutBounds.Height;
        if (y < 0) { Model.MoveCaret(0, extend); return; }
        if (y > docHeight) { Model.MoveCaret(Model.Buffer.Length, extend); return; }
        var offset = HitOffset(new Windows.Foundation.Point(_desiredX + Left, y + DocPadding - _scroll));
        Model.MoveCaret(offset, extend);
    }

    private void MoveToVisualLineEdge(bool start, bool extend)
    {
        var layout = EnsureLayout();
        var rect = CaretRect(Model.Caret);
        var y = rect.Y + rect.Height / 2;
        var x = start ? 0 : ColumnWidth;
        var offset = HitOffset(new Windows.Foundation.Point(x + Left, y + DocPadding - _scroll));
        // End on a wrapped line must stay before the soft break, not at the start of the next line.
        if (!start && offset > 0 && offset <= Model.Buffer.Length && offset < Model.Buffer.Length && Model.Buffer.Text[offset - 1] == ' ')
            offset = Math.Max(offset - 0, 0);
        Model.MoveCaret(offset, extend);
    }

    // ---- clipboard ------------------------------------------------------------------------------

    private void Copy(bool cut)
    {
        if (!Model.HasSelection) return;
        var package = new DataPackage();
        var sel = Model.Selection;
        package.SetText(Model.Buffer.Slice(sel.Start, sel.Length).Replace("\n", "\r\n"));
        Clipboard.SetContent(package);
        if (cut) Model.Insert("");
    }

    private async Task PasteAsync()
    {
        var view = Clipboard.GetContent();
        if (!view.Contains(StandardDataFormats.Text)) return;
        var text = await view.GetTextAsync();
        Model.Insert(text.Replace("\r\n", "\n").Replace('\r', '\n'));
    }
}
