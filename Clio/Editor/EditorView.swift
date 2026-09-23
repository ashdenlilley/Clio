import AppKit
import SwiftUI

struct SlashCommandPresentation {
    /// Caret rectangle in top-left-oriented window content coordinates.
    var anchor: CGRect?
    var restoreLiteral: @MainActor (String) -> Void = { _ in }
}

struct EditorConfiguration: Equatable {
    var fontName: String
    var fontSize: CGFloat
    var measure: Int
    var lineHeightMultiple: CGFloat
    var isSpellCheckingEnabled: Bool
    var isTypewriterScrollingEnabled: Bool
    var typewriterAnchor: CGFloat
    var isFocusModeEnabled: Bool
    var focusDimmingOpacity: CGFloat
    var accent: AppState.AccentPreset
    var caretStyle: CaretStyle
    var isGrammarCheckingEnabled: Bool
    var isSmartPunctuationEnabled: Bool
    var autoWrapsSelection: Bool

    init(
        fontSize: CGFloat = Typography.baseSize,
        fontName: String = "Hack-Regular",
        measure: Int = Metrics.measure,
        lineHeightMultiple: CGFloat = Typography.lineHeight,
        isSpellCheckingEnabled: Bool = true,
        isTypewriterScrollingEnabled: Bool = true,
        typewriterAnchor: CGFloat = 0.45,
        isFocusModeEnabled: Bool = true,
        focusDimmingOpacity: CGFloat = 0.28,
        accent: AppState.AccentPreset = .clio,
        caretStyle: CaretStyle = .block,
        isGrammarCheckingEnabled: Bool = false,
        isSmartPunctuationEnabled: Bool = false,
        autoWrapsSelection: Bool = true
    ) {
        self.fontSize = fontSize
        self.fontName = fontName
        self.measure = measure
        self.lineHeightMultiple = lineHeightMultiple
        self.isSpellCheckingEnabled = isSpellCheckingEnabled
        self.isTypewriterScrollingEnabled = isTypewriterScrollingEnabled
        self.typewriterAnchor = typewriterAnchor
        self.isFocusModeEnabled = isFocusModeEnabled
        self.focusDimmingOpacity = focusDimmingOpacity
        self.accent = accent
        self.caretStyle = caretStyle
        self.isGrammarCheckingEnabled = isGrammarCheckingEnabled
        self.isSmartPunctuationEnabled = isSmartPunctuationEnabled
        self.autoWrapsSelection = autoWrapsSelection
    }

    var resolvedFontSize: CGFloat { min(max(fontSize, 12), 20) }
    var resolvedMeasure: Int { min(max(measure, 60), 90) }
    var resolvedLineHeightMultiple: CGFloat { min(max(lineHeightMultiple, 1), 2.5) }
    var resolvedTypewriterAnchor: CGFloat { min(max(typewriterAnchor, 0.30), 0.60) }
    var resolvedFocusDimmingOpacity: CGFloat { min(max(focusDimmingOpacity, 0.05), 1) }
}

struct EditorView: NSViewRepresentable {
    private var text: String
    private var contentGeneration: BufferGeneration
    private var viewport: Binding<EditorViewportState>?
    private var configuration: EditorConfiguration
    private var onTextEdit: @MainActor (MarkdownTextEdit) -> Void
    private var onSlashCommand: (@MainActor (SlashCommandPresentation) -> Void)?
    private var onPlainTextPasted: (@MainActor (String, NSRange, NSTextView) -> Void)?
    private var minimap: EditorMinimapModel?
    private var onEditorReady: (@MainActor (NSTextView) -> Void)?

    init(
        text: String,
        contentGeneration: BufferGeneration,
        viewport: Binding<EditorViewportState>? = nil,
        configuration: EditorConfiguration = EditorConfiguration(),
        onTextEdit: @escaping @MainActor (MarkdownTextEdit) -> Void,
        onSlashCommand: (@MainActor (SlashCommandPresentation) -> Void)? = nil,
        onPlainTextPasted: (@MainActor (String, NSRange, NSTextView) -> Void)? = nil,
        minimap: EditorMinimapModel? = nil,
        onEditorReady: (@MainActor (NSTextView) -> Void)? = nil
    ) {
        self.text = text
        self.contentGeneration = contentGeneration
        self.viewport = viewport
        self.configuration = configuration
        self.onTextEdit = onTextEdit
        self.onSlashCommand = onSlashCommand
        self.onPlainTextPasted = onPlainTextPasted
        self.minimap = minimap
        self.onEditorReady = onEditorReady
    }

    func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator(
            configuration: configuration,
            viewport: viewport,
            onTextEdit: onTextEdit,
            onSlashCommand: onSlashCommand,
            onPlainTextPasted: onPlainTextPasted,
            minimap: minimap
        )
    }

    func makeNSView(context: Context) -> EditorContainerView {
        let textView = EditorTextView.makeTextKit2TextView()
        let surface = EditorContainerView(textView: textView)
        context.coordinator.attach(to: surface)
        context.coordinator.update(
            text: text,
            contentGeneration: contentGeneration,
            configuration: configuration,
            viewport: viewport,
            onTextEdit: onTextEdit,
            onSlashCommand: onSlashCommand,
            onPlainTextPasted: onPlainTextPasted
        )
        onEditorReady?(textView)
        return surface
    }

    func updateNSView(_ nsView: EditorContainerView, context: Context) {
        onEditorReady?(nsView.textView)
        context.coordinator.update(
            text: text,
            contentGeneration: contentGeneration,
            configuration: configuration,
            viewport: viewport,
            onTextEdit: onTextEdit,
            onSlashCommand: onSlashCommand,
            onPlainTextPasted: onPlainTextPasted
        )
    }

    static func dismantleNSView(_ nsView: EditorContainerView, coordinator: EditorCoordinator) {
        coordinator.detach()
        nsView.prepareForRemoval()
    }
}

final class EditorContainerView: NSView {
    let scrollView: NSScrollView
    let textView: EditorTextView

    var onViewportSizeChanged: (() -> Void)?

    private var preferredTextWidth: CGFloat = 0
    private var lastViewportSize = NSSize.zero
    private var hasRequestedInitialFocus = false
    private var isPreparedForRemoval = false
    private var scrollerStyleObserver: NSObjectProtocol?
    var reservesNativeScroller: Bool { NSScroller.preferredScrollerStyle == .legacy }

    init(textView: EditorTextView) {
        self.textView = textView
        scrollView = NSScrollView(frame: .zero)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = Palette.background.cgColor
        focusRingType = .none
        setAccessibilityIdentifier("editor.surface.no-focus-ring")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.focusRingType = .none
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.background
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = Palette.background
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = reservesNativeScroller
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = reservesNativeScroller ? .legacy : .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .automatic
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = textView

        textView.frame = NSRect(origin: .zero, size: NSSize(width: 1, height: 1))
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        scrollerStyleObserver = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.needsLayout = true
                self?.onViewportSizeChanged?()
            }
        }
    }

    deinit {
        if let scrollerStyleObserver { NotificationCenter.default.removeObserver(scrollerStyleObserver) }
    }

    func prepareForRemoval() {
        guard !isPreparedForRemoval else { return }
        isPreparedForRemoval = true
        onViewportSizeChanged = nil
        if let scrollerStyleObserver {
            NotificationCenter.default.removeObserver(scrollerStyleObserver)
            self.scrollerStyleObserver = nil
        }
        // Do not change editable/selectable/rich-text flags during teardown:
        // those setters can enqueue AppKit drag-registration work.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EditorContainerView is created programmatically")
    }

    override func layout() {
        super.layout()

        scrollView.hasVerticalScroller = reservesNativeScroller
        scrollView.scrollerStyle = reservesNativeScroller ? .legacy : .overlay
        let viewportSize = scrollView.contentSize
        // Only the text column is constrained; the native scrollbar belongs
        // to the far edge of the full editor viewport.
        let inset = max(Metrics.horizontalPadding, (viewportSize.width - preferredTextWidth) / 2)
        if abs(textView.textContainerInset.width - inset) > 0.5 {
            textView.invalidateBlockCaret()
            textView.textContainerInset = NSSize(width: inset, height: textView.textContainerInset.height)
        }
        textView.minSize = NSSize(width: 0, height: viewportSize.height)
        if abs(textView.frame.width - viewportSize.width) > 0.5 {
            textView.setFrameSize(
                NSSize(
                    width: viewportSize.width,
                    height: max(textView.frame.height, viewportSize.height)
                )
            )
        }

        guard viewportSize != lastViewportSize else { return }
        lastViewportSize = viewportSize
        textView.invalidateBlockCaret()
        onViewportSizeChanged?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !hasRequestedInitialFocus, !isPreparedForRemoval else { return }
        hasRequestedInitialFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isPreparedForRemoval, let window = self.window else { return }
            // A palette or another text field may have claimed focus while
            // SwiftUI attached this editor during the same update.
            if let responder = window.firstResponder as? NSTextView,
               responder !== self.textView { return }
            window.makeFirstResponder(self.textView)
        }
    }

    func apply(configuration: EditorConfiguration) {
        textView.applyEditorConfiguration(configuration)
        let font = Typography.font(size: configuration.resolvedFontSize, name: configuration.fontName)
        let textWidth = Typography.characterAdvance(for: font)
            * CGFloat(configuration.resolvedMeasure)
        preferredTextWidth = ceil(textWidth)
        needsLayout = true
    }
}
