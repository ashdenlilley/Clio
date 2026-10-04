using System.Runtime.InteropServices;
using Clio.Editor.Automation;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Automation.Text;
using Microsoft.UI.Xaml.Controls;

namespace Clio.App;

/// <summary>
/// The IME proxy owns keyboard focus, so it is also what assistive technology sees as the focused element. Its peer
/// presents the document: a Document control with a Text pattern served by the editor, not the proxy's empty text.
/// </summary>
internal sealed class ImeProxyTextBox : TextBox
{
    public EditorControl? Editor { get; set; }

    protected override AutomationPeer OnCreateAutomationPeer() => new EditorAutomationPeer(this);
}

/// <summary>The editor as a container pane around its Document element. It also gives the control a peer, which
/// supplies the screen origin that text-range rectangles are measured from.</summary>
internal sealed class EditorPanePeer(EditorControl owner) : FrameworkElementAutomationPeer(owner)
{
    protected override string GetClassNameCore() => "ClioEditorPane";

    protected override string GetNameCore() => "Editor";

    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Pane;

    protected override bool IsContentElementCore() => false;
}

internal sealed class EditorAutomationPeer : FrameworkElementAutomationPeer
{
    private readonly ImeProxyTextBox _owner;
    private EditorTextProvider? _text;

    public EditorAutomationPeer(ImeProxyTextBox owner) : base(owner) => _owner = owner;

    protected override string GetClassNameCore() => "ClioEditor";

    protected override string GetNameCore() => "Document";

    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Document;

    // The document is the whole editor, not the 4 px proxy that happens to hold keyboard focus.
    protected override Windows.Foundation.Rect GetBoundingRectangleCore() =>
        _owner.Editor is { } editor && FromElement(editor) is { } pane ? pane.GetBoundingRectangle() : base.GetBoundingRectangleCore();

    protected override Windows.Foundation.Point GetClickablePointCore() =>
        GetBoundingRectangleCore() is { Width: > 0 } r ? new Windows.Foundation.Point(r.X + r.Width / 2, r.Y + r.Height / 2) : base.GetClickablePointCore();

    protected override string GetHelpTextCore() => "Markdown document. Type to write; slash opens commands.";

    protected override object? GetPatternCore(PatternInterface patternInterface)
    {
        switch (patternInterface)
        {
            case PatternInterface.Text:
                return _owner.Editor is { } editor ? _text ??= new EditorTextProvider(editor, () => ProviderFromPeer(this)) : null;
            // Deliberately no Value pattern: the proxy's own value is always empty, and exposing it would tell a
            // screen reader the document is blank. The peer is not a TextBoxAutomationPeer for the same reason: that
            // class serves its own native Text and Value patterns whatever is returned here.
            default:
                return base.GetPatternCore(patternInterface);
        }
    }
}

internal sealed class EditorTextProvider(EditorControl editor, Func<IRawElementProviderSimple> element) : ITextProvider
{
    public ITextRangeProvider DocumentRange => new EditorTextRange(editor, 0, editor.TextSource.Text.Length, element);

    public SupportedTextSelection SupportedTextSelection => SupportedTextSelection.Single;

    public ITextRangeProvider[] GetSelection()
    {
        var (start, end) = editor.SelectionOffsets;
        return [new EditorTextRange(editor, start, end, element)];
    }

    public ITextRangeProvider[] GetVisibleRanges()
    {
        var (start, end) = editor.VisibleOffsets();
        return [new EditorTextRange(editor, start, end, element)];
    }

    public ITextRangeProvider RangeFromChild(IRawElementProviderSimple childElement) => DocumentRange;

    public ITextRangeProvider RangeFromPoint(Windows.Foundation.Point screenLocation)
    {
        var offset = editor.OffsetFromScreenPoint(screenLocation);
        return new EditorTextRange(editor, offset, offset, element);
    }
}

internal sealed class EditorTextRange(EditorControl editor, int start, int end, Func<IRawElementProviderSimple> element) : ITextRangeProvider
{
    private int _start = start;
    private int _end = end;

    internal EditorControl Editor => editor;

    private IUiaTextSource Source => editor.TextSource;

    private static UiaUnit Unit(TextUnit unit) => unit switch
    {
        TextUnit.Character => UiaUnit.Character,
        TextUnit.Format => UiaUnit.Format,
        TextUnit.Word => UiaUnit.Word,
        TextUnit.Line => UiaUnit.Line,
        TextUnit.Paragraph => UiaUnit.Paragraph,
        TextUnit.Page => UiaUnit.Page,
        _ => UiaUnit.Document,
    };

    private EditorTextRange Own(ITextRangeProvider range) =>
        range as EditorTextRange is { } r && ReferenceEquals(r.Editor, editor)
            ? r
            : throw new ArgumentException("Range belongs to another document.", nameof(range));

    public ITextRangeProvider Clone() => new EditorTextRange(editor, _start, _end, element);

    public bool Compare(ITextRangeProvider range) =>
        range is EditorTextRange r && ReferenceEquals(r.Editor, editor) && r._start == _start && r._end == _end;

    public int CompareEndpoints(TextPatternRangeEndpoint endpoint, ITextRangeProvider targetRange, TextPatternRangeEndpoint targetEndpoint)
    {
        var target = Own(targetRange);
        return UiaTextMath.CompareEndpoints(_start, _end, endpoint == TextPatternRangeEndpoint.End,
            target._start, target._end, targetEndpoint == TextPatternRangeEndpoint.End);
    }

    public void ExpandToEnclosingUnit(TextUnit unit) => (_start, _end) = UiaTextMath.Expand(Source, _start, _end, Unit(unit));

    public ITextRangeProvider? FindAttribute(int attributeId, object value, bool backward) => null;

    public ITextRangeProvider? FindText(string text, bool backward, bool ignoreCase) =>
        UiaTextMath.Find(Source, _start, _end, text, backward, ignoreCase) is { } hit
            ? new EditorTextRange(editor, hit.Start, hit.End, element)
            : null;

    // Presentation attributes are not text formatting: the editor styles Markdown source, it does not store formatting.
    public object GetAttributeValue(int attributeId) => attributeId switch
    {
        40015 => false, // UIA_IsReadOnlyAttributeId
        40005 => "Hack", // UIA_FontNameAttributeId
        _ => DependencyProperty.UnsetValue,
    };

    public void GetBoundingRectangles(out double[] returnValue) => returnValue = editor.ScreenRectangles(_start, _end);

    public IRawElementProviderSimple[] GetChildren() => [];

    public IRawElementProviderSimple GetEnclosingElement() => element();

    public string GetText(int maxLength) => UiaTextMath.GetText(Source, _start, _end, maxLength);

    public int Move(TextUnit unit, int count)
    {
        (_start, _end, var moved) = UiaTextMath.Move(Source, _start, _end, Unit(unit), count);
        return moved;
    }

    public void MoveEndpointByRange(TextPatternRangeEndpoint endpoint, ITextRangeProvider targetRange, TextPatternRangeEndpoint targetEndpoint)
    {
        var target = Own(targetRange);
        var position = targetEndpoint == TextPatternRangeEndpoint.End ? target._end : target._start;
        if (endpoint == TextPatternRangeEndpoint.End)
        {
            _end = position;
            if (_end < _start) _start = _end;
        }
        else
        {
            _start = position;
            if (_start > _end) _end = _start;
        }
    }

    public int MoveEndpointByUnit(TextPatternRangeEndpoint endpoint, TextUnit unit, int count)
    {
        (_start, _end, var moved) = UiaTextMath.MoveEndpoint(Source, _start, _end, endpoint == TextPatternRangeEndpoint.End, Unit(unit), count);
        return moved;
    }

    public void Select() => editor.SelectOffsets(_start, _end);

    // Single selection only (SupportedTextSelection.Single): adding to or removing from it is not supported.
    public void AddToSelection() => throw new InvalidOperationException("Multiple selection is not supported.");

    public void RemoveFromSelection() => throw new InvalidOperationException("Multiple selection is not supported.");

    public void ScrollIntoView(bool alignToTop) => editor.ScrollOffsetIntoView(alignToTop ? _start : _end, alignToTop);
}
