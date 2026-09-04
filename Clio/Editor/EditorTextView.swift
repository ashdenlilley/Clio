import AppKit

/// Owns the TextKit 2 object graph used by `EditorTextView`.
///
/// `NSTextContainer` and `NSTextLayoutManager` only retain parts of this graph,
/// so the text view keeps this object alive for its entire lifetime.
private final class EditorTextKitStack {
    let contentStorage: NSTextContentStorage
    let layoutManager: NSTextLayoutManager
    let textContainer: NSTextContainer

    init() {
        contentStorage = NSTextContentStorage()
        layoutManager = NSTextLayoutManager()
        textContainer = NSTextContainer(size: .zero)

        contentStorage.addTextLayoutManager(layoutManager)
        contentStorage.primaryTextLayoutManager = layoutManager
        layoutManager.textContainer = textContainer
    }
}

final class EditorTextView: NSTextView {
    var onUserScroll: (() -> Void)?
    var onKeyEventBegan: (() -> Void)?
    var onKeyEventEnded: (() -> Void)?

    private var retainedTextKitStack: AnyObject?

    static func makeTextKit2TextView() -> EditorTextView {
        let stack = EditorTextKitStack()
        let textView = EditorTextView(frame: .zero, textContainer: stack.textContainer)
        textView.retainedTextKitStack = stack
        textView.setAccessibilityIdentifier("editor.text")
        return textView
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        onKeyEventBegan?()
        super.keyDown(with: event)
        onKeyEventEnded?()
    }

    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            onUserScroll?()
        }
        super.scrollWheel(with: event)
    }

    override func drawInsertionPoint(
        in rect: NSRect,
        color: NSColor,
        turnedOn flag: Bool
    ) {
        var caretRect = rect
        caretRect.size.width = 2
        super.drawInsertionPoint(in: caretRect, color: Palette.caret, turnedOn: flag)
    }

    func applyEditorConfiguration(_ configuration: EditorConfiguration) {
        let font = Typography.font(size: configuration.resolvedFontSize)
        let paragraphStyle = Typography.paragraphStyle(
            fontSize: configuration.resolvedFontSize,
            lineHeightMultiple: configuration.resolvedLineHeightMultiple
        )

        drawsBackground = true
        backgroundColor = Palette.background
        textColor = Palette.foreground
        insertionPointColor = Palette.caret
        selectedTextAttributes = [.backgroundColor: Palette.selection]
        focusRingType = .none

        isEditable = true
        isSelectable = true
        allowsUndo = true
        isRichText = false
        importsGraphics = false
        allowsImageEditing = false
        usesFontPanel = false
        usesRuler = false
        isRulerVisible = false

        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isGrammarCheckingEnabled = false
        isContinuousSpellCheckingEnabled = configuration.isSpellCheckingEnabled
        smartInsertDeleteEnabled = false

        isHorizontallyResizable = false
        isVerticallyResizable = true
        autoresizingMask = [.width]
        textContainerInset = NSSize(
            width: Metrics.horizontalPadding,
            height: Metrics.verticalPadding
        )

        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        textContainer?.heightTracksTextView = false
        textContainer?.maximumNumberOfLines = 0
        textLayoutManager?.usesFontLeading = false
        textLayoutManager?.usesHyphenation = false

        self.font = font
        defaultParagraphStyle = paragraphStyle
        typingAttributes = Self.baseAttributes(font: font, paragraphStyle: paragraphStyle)
    }

    func applyBaseAttributes(for configuration: EditorConfiguration) {
        let font = Typography.font(size: configuration.resolvedFontSize)
        let paragraphStyle = Typography.paragraphStyle(
            fontSize: configuration.resolvedFontSize,
            lineHeightMultiple: configuration.resolvedLineHeightMultiple
        )
        let attributes = Self.baseAttributes(font: font, paragraphStyle: paragraphStyle)

        typingAttributes = attributes
        guard let textStorage, textStorage.length > 0 else { return }
        textStorage.beginEditing()
        textStorage.setAttributes(
            attributes,
            range: NSRange(location: 0, length: textStorage.length)
        )
        textStorage.endEditing()
    }

    private static func baseAttributes(
        font: NSFont,
        paragraphStyle: NSParagraphStyle
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: Palette.foreground,
            .paragraphStyle: paragraphStyle,
            .ligature: 0
        ]
    }
}
