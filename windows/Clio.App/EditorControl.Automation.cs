using Clio.Editor.Automation;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;

namespace Clio.App;

/// <summary>Document text, selection and geometry for the UI Automation Text pattern (see <see cref="EditorAutomationPeer"/>).</summary>
public sealed partial class EditorControl
{
    private IReadOnlyList<int> _lineStarts = [];
    private Microsoft.Graphics.Canvas.Text.CanvasTextLayout? _lineStartsLayout;

    protected override AutomationPeer OnCreateAutomationPeer() => new EditorPanePeer(this);

    internal IUiaTextSource TextSource => new LiveTextSource(this);

    internal (int Start, int End) SelectionOffsets => (Model.Selection.Start, Model.Selection.End);

    internal void SelectOffsets(int start, int end) => Model.SetSelection(start, end);

    private sealed class LiveTextSource(EditorControl editor) : IUiaTextSource
    {
        public string Text => editor.Model.Buffer.Text;

        public IReadOnlyList<int> VisualLineStarts => editor.VisualLineStarts();
    }

    /// <summary>Where each wrapped line starts. Empty (logical lines) while an IME composition shifts the layout offsets.</summary>
    private IReadOnlyList<int> VisualLineStarts()
    {
        if (_composition.Length > 0) return [];
        var layout = EnsureLayout();
        if (ReferenceEquals(layout, _lineStartsLayout)) return _lineStarts;
        var starts = new List<int>();
        var offset = 0;
        foreach (var line in layout.LineMetrics)
        {
            starts.Add(offset);
            offset += line.CharacterCount;
        }
        _lineStartsLayout = layout;
        return _lineStarts = starts;
    }

    internal (int Start, int End) VisibleOffsets()
    {
        var top = HitOffset(new Windows.Foundation.Point(Left, 0));
        var bottom = HitOffset(new Windows.Foundation.Point(Left + ColumnWidth, _canvas.ActualHeight));
        return (Math.Min(top, bottom), Math.Max(top, bottom));
    }

    /// <summary>Screen-pixel rectangles (x, y, width, height, ...) covering the characters, one per visual line.</summary>
    internal double[] ScreenRectangles(int start, int end)
    {
        var layout = EnsureLayout();
        var rectangles = new List<Windows.Foundation.Rect>();
        if (end > start)
        {
            foreach (var region in layout.GetCharacterRegions(start, end - start))
                rectangles.Add(region.LayoutBounds);
        }
        else
        {
            var caret = CaretRect(start);
            rectangles.Add(new Windows.Foundation.Rect(caret.X, caret.Y, 1, caret.Height));
        }

        var origin = new Windows.Foundation.Point(Left, DocPadding - _scroll);
        var result = new List<double>(rectangles.Count * 4);
        foreach (var rect in rectangles)
        {
            var topLeft = ToScreen(new Windows.Foundation.Point(origin.X + rect.X, origin.Y + rect.Y));
            var scale = XamlRoot?.RasterizationScale ?? 1.0;
            result.AddRange([topLeft.X, topLeft.Y, Math.Max(1, rect.Width * scale), rect.Height * scale]);
        }
        return [.. result];
    }

    internal int OffsetFromScreenPoint(Windows.Foundation.Point screen)
    {
        var scale = XamlRoot?.RasterizationScale ?? 1.0;
        var origin = ScreenOrigin();
        return HitOffset(new Windows.Foundation.Point((screen.X - origin.X) / scale, (screen.Y - origin.Y) / scale));
    }
    internal void ScrollOffsetIntoView(int offset, bool alignToTop)
    {
        var rect = CaretRect(Math.Clamp(offset, 0, Model.Buffer.Length));
        var top = DocPadding + rect.Y;
        _ease.Stop();
        _manualScroll = true;
        _scroll = ClampScroll(alignToTop ? top - 24 : top + rect.Height - _canvas.ActualHeight + 24);
        _canvas.Invalidate();
    }

    private (double X, double Y) ToScreen(Windows.Foundation.Point local)
    {
        var scale = XamlRoot?.RasterizationScale ?? 1.0;
        var origin = ScreenOrigin();
        return (origin.X + local.X * scale, origin.Y + local.Y * scale);
    }

    /// <summary>
    /// Top-left of this control in screen pixels, as the framework's own peer reports it. Going through the peer
    /// (rather than the window handle plus TransformToVisual) keeps these coordinates identical to every other
    /// element's, whatever the window chrome, DPI or title-bar mode.
    /// </summary>
    private Windows.Foundation.Point ScreenOrigin()
    {
        var peer = FrameworkElementAutomationPeer.FromElement(this) ?? FrameworkElementAutomationPeer.CreatePeerForElement(this);
        var bounds = peer.GetBoundingRectangle();
        return new Windows.Foundation.Point(bounds.X, bounds.Y);
    }
    /// <summary>Tell assistive technology the selection or text moved, if anything is listening.</summary>
    private void RaiseUiaEvent(AutomationEvents kind)
    {
        if (!AutomationPeer.ListenerExists(kind)) return;
        FrameworkElementAutomationPeer.FromElement(_proxy)?.RaiseAutomationEvent(kind);
    }
}
