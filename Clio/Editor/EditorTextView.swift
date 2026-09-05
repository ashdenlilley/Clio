import AppKit
import QuartzCore

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
    var onMarkdownAction: ((MarkdownEditorAction) -> Bool)?

    private var retainedTextKitStack: AnyObject?
    private let blockCaret = CALayer()
    private var isProcessingKeyEvent = false
    var managesTypingScroll = false

    static func makeTextKit2TextView() -> EditorTextView {
        let stack = EditorTextKitStack()
        let textView = EditorTextView(frame: .zero, textContainer: stack.textContainer)
        textView.retainedTextKitStack = stack
        textView.setAccessibilityIdentifier("editor.text")
        return textView
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        isProcessingKeyEvent = true
        onKeyEventBegan?()
        defer { isProcessingKeyEvent = false; onKeyEventEnded?() }
        if let action = markdownShortcut(for: event), onMarkdownAction?(action) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        guard onMarkdownAction?(.newline) != true else { return }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        guard onMarkdownAction?(.indent) != true else { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        guard onMarkdownAction?(.outdent) != true else { return }
        super.insertBacktab(sender)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if selectedRange().length > 0,
           let value = insertString as? String,
           let style = wrapStyle(forTypedMarker: value),
           onMarkdownAction?(.wrap(style)) == true {
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func paste(_ sender: Any?) {
        if let value = NSPasteboard.general.string(forType: .string),
           onMarkdownAction?(.paste(value)) == true { return }
        super.paste(sender)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            onUserScroll?()
        }
        super.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        // Never move the document under a click/drag while AppKit selects text.
        onUserScroll?()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onUserScroll?()
        super.rightMouseDown(with: event)
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        // AppKit's automatic key-event scrolling otherwise jumps before the
        // typewriter controller can perform its smooth return animation.
        guard !(managesTypingScroll && isProcessingKeyEvent) else { return }
        super.scrollRangeToVisible(range)
    }

    func invalidateBlockCaret() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blockCaret.isHidden = true
        CATransaction.commit()
        needsDisplay = true
        updateInsertionPointStateAndRestartTimer(true)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { blockCaret.isHidden = true }
        return resigned
    }

    override func drawInsertionPoint(
        in rect: NSRect,
        color: NSColor,
        turnedOn flag: Bool
    ) {
        // AppKit owns blink timing. A retained overlay owns the wider block:
        // never paint outside AppKit's narrow caret invalidation rectangle.
        // Moving/resizing the editor therefore cannot leave painted ghost bars.
        if blockCaret.superlayer == nil {
            wantsLayer = true
            layer?.addSublayer(blockCaret)
        }
        let caretFont = font ?? Typography.font()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blockCaret.frame = NSRect(x: rect.minX, y: rect.minY,
                                  width: Typography.characterAdvance(for: caretFont), height: rect.height)
        blockCaret.backgroundColor = insertionPointColor.withAlphaComponent(0.75).cgColor
        blockCaret.isHidden = !flag || selectedRange().length != 0 || window?.isKeyWindow != true
        CATransaction.commit()
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
        insertionPointColor = configuration.accent.nsColor
        selectedTextAttributes = [.backgroundColor: configuration.accent.nsColor.withAlphaComponent(0.55)]
        managesTypingScroll = configuration.isTypewriterScrollingEnabled
        invalidateBlockCaret()
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

    private func markdownShortcut(for event: NSEvent) -> MarkdownEditorAction? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        if key == "b", modifiers.subtracting(.command).isEmpty { return .wrap(.strong) }
        if key == "i", modifiers.subtracting(.command).isEmpty { return .wrap(.emphasis) }
        if key == "x", modifiers.contains(.shift) { return .wrap(.strikethrough) }
        if key == "k", modifiers.contains(.shift) { return .wrap(.code) }
        return nil
    }

    private func wrapStyle(forTypedMarker marker: String) -> MarkdownWrapStyle? {
        switch marker {
        case "*": return .emphasis
        case "_": return .emphasisUnderscore
        case "~": return .strikethrough
        case "`": return .code
        default: return nil
        }
    }
}
