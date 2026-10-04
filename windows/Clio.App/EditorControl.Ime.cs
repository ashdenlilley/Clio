using Clio.Editor;
using Clio.Editor.Markdown;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Clio.App;

/// <summary>
/// Text input and IME composition. The editor draws its own text, so a transparent, caret-following
/// <see cref="TextBox"/> receives the system's text services (typing, dead keys, emoji picker, IME) and the
/// control mirrors it: committed text is moved into the model and the proxy emptied, an open composition is
/// drawn inline and underlined at the caret and anchors the candidate window to it.
/// <para>
/// This is a deliberate substitute for <c>CoreTextEditContext</c>: the Windows App SDK packages used here do
/// not ship <c>Microsoft.UI.Text.Core</c>, and the Windows SDK type needs a CoreWindow that an unpackaged
/// WinUI 3 window does not have. Not yet exercised with a real IME; see spec/PARITY.md.
/// </para>
/// </summary>
public sealed partial class EditorControl
{
    private readonly ImeProxyTextBox _proxy = new()
    {
        Width = 4,
        MinWidth = 0,
        MinHeight = 0,
        Height = LineHeight,
        Padding = new Thickness(0),
        BorderThickness = new Thickness(0),
        Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
        Foreground = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
        Opacity = 0,
        IsSpellCheckEnabled = false,
        IsTextPredictionEnabled = false,
        AcceptsReturn = false,
        TextWrapping = TextWrapping.NoWrap,
        IsTabStop = true,
        UseSystemFocusVisuals = false,
    };

    private string _composition = "";
    private bool _composing;

    /// <summary>An IME composition is open: the text shown is not yet in the model (macOS "marked text").</summary>
    public bool IsComposing => _composing;

    private double _proxyX = double.NaN, _proxyY = double.NaN;

    /// <summary>Model text with the open composition spliced in at the caret; what the layout shows.</summary>
    private string DisplayText => _composition.Length == 0 ? Model.Buffer.Text : Model.Buffer.Text.Insert(Model.Caret, _composition);

    private int DisplayCaret => Model.Caret + _composition.Length;

    private UIElement BuildContent()
    {
        var overlay = new Microsoft.UI.Xaml.Controls.Canvas { IsHitTestVisible = false };
        overlay.Children.Add(_proxy);
        var root = new Grid();
        root.Children.Add(_canvas);
        root.Children.Add(overlay);
        return root;
    }

    private void InitIme()
    {
        _proxy.Editor = this;
        _proxy.TextChanged += (_, _) => FlushProxy();
        _proxy.TextCompositionStarted += (_, _) =>
        {
            _composing = true;
            // A composition replaces the selection, like typing does.
            if (Model.HasSelection) Model.Insert("");
        };
        _proxy.TextCompositionChanged += (sender, args) =>
        {
            var text = sender.Text;
            var start = Math.Clamp(args.StartIndex, 0, text.Length);
            var length = Math.Clamp(args.Length, 0, text.Length - start);
            SetComposition(text.Substring(start, length));
        };
        _proxy.TextCompositionEnded += (_, _) =>
        {
            _composing = false;
            SetComposition("");
            FlushProxy(fromComposition: true);
        };
    }

    /// <summary>Drop any open composition and pending proxy text (document replaced).</summary>
    private void ResetIme()
    {
        _composing = false;
        _composition = "";
        if (_proxy.Text.Length > 0) _proxy.Text = "";
    }

    private void SetComposition(string value)
    {
        if (_composition == value) return;
        _composition = value;
        _layout = null;
        _canvas.Invalidate();
    }

    /// <summary>Move committed proxy text into the model. No-op while a composition is open.</summary>
    private void FlushProxy(bool fromComposition = false)
    {
        if (_composing) return;
        var text = _proxy.Text;
        if (text.Length == 0) return;
        _proxy.Text = "";
        text = text.Replace("\r\n", "\n").Replace('\r', '\n');
        // A typed "/" opens the command palette instead (never for text an IME just committed).
        if (TryRaiseSlash(text, fromComposition)) return;
        // A single character (or surrogate pair) coalesces into one undo step; committed strings do not.
        Model.Insert(text, typing: text.Length <= 2, nowMs: Environment.TickCount64);
        _desiredX = -1;
    }

    /// <summary>Keep the proxy on the caret so the IME candidate window opens next to what is being typed.</summary>
    private void PositionProxy(double x, double y)
    {
        if (x.Equals(_proxyX) && y.Equals(_proxyY)) return;
        (_proxyX, _proxyY) = (x, y);
        Microsoft.UI.Xaml.Controls.Canvas.SetLeft(_proxy, x);
        Microsoft.UI.Xaml.Controls.Canvas.SetTop(_proxy, y);
    }

    // ---- composition-aware coordinates ----------------------------------------------------------

    /// <summary>
    /// Spans in display coordinates: spans before the caret stay, those after it shift by the composition
    /// length, those containing the caret grow, so styling survives while composing.
    /// </summary>
    private IReadOnlyList<MarkdownSpan> DisplaySpans(IReadOnlyList<MarkdownSpan> spans)
    {
        if (_composition.Length == 0) return spans;
        var at = Model.Caret;
        var extra = _composition.Length;
        var mapped = new List<MarkdownSpan>(spans.Count);
        foreach (var s in spans)
        {
            if (s.End <= at) mapped.Add(s);
            else if (s.Start >= at) mapped.Add(s with { Start = s.Start + extra });
            else mapped.Add(s with { Length = s.Length + extra });
        }
        return mapped;
    }

    private TextRange DisplayRange(TextRange range)
    {
        if (_composition.Length == 0) return range;
        var at = Model.Caret;
        var extra = _composition.Length;
        var start = range.Start > at ? range.Start + extra : range.Start;
        var end = range.End >= at ? range.End + extra : range.End;
        return new TextRange(start, Math.Max(0, end - start));
    }
}
