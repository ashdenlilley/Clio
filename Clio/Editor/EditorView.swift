import AppKit
import SwiftUI

struct EditorConfiguration: Equatable {
    var fontSize: CGFloat
    var measure: Int
    var lineHeightMultiple: CGFloat
    var isSpellCheckingEnabled: Bool
    var isTypewriterScrollingEnabled: Bool
    var typewriterAnchor: CGFloat
    var isFocusModeEnabled: Bool
    var focusDimmingOpacity: CGFloat

    init(
        fontSize: CGFloat = Typography.baseSize,
        measure: Int = Metrics.measure,
        lineHeightMultiple: CGFloat = Typography.lineHeight,
        isSpellCheckingEnabled: Bool = true,
        isTypewriterScrollingEnabled: Bool = true,
        typewriterAnchor: CGFloat = 0.45,
        isFocusModeEnabled: Bool = true,
        focusDimmingOpacity: CGFloat = 0.28
    ) {
        self.fontSize = fontSize
        self.measure = measure
        self.lineHeightMultiple = lineHeightMultiple
        self.isSpellCheckingEnabled = isSpellCheckingEnabled
        self.isTypewriterScrollingEnabled = isTypewriterScrollingEnabled
        self.typewriterAnchor = typewriterAnchor
        self.isFocusModeEnabled = isFocusModeEnabled
        self.focusDimmingOpacity = focusDimmingOpacity
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
    private var onSlashCommand: (@MainActor () -> Void)?

    init(
        text: String,
        contentGeneration: BufferGeneration,
        viewport: Binding<EditorViewportState>? = nil,
        configuration: EditorConfiguration = EditorConfiguration(),
        onTextEdit: @escaping @MainActor (MarkdownTextEdit) -> Void,
        onSlashCommand: (@MainActor () -> Void)? = nil
    ) {
        self.text = text
        self.contentGeneration = contentGeneration
        self.viewport = viewport
        self.configuration = configuration
        self.onTextEdit = onTextEdit
        self.onSlashCommand = onSlashCommand
    }

    func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator(
            configuration: configuration,
            viewport: viewport,
            onTextEdit: onTextEdit,
            onSlashCommand: onSlashCommand
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
            onSlashCommand: onSlashCommand
        )
        return surface
    }

    func updateNSView(_ nsView: EditorContainerView, context: Context) {
        context.coordinator.update(
            text: text,
            contentGeneration: contentGeneration,
            configuration: configuration,
            viewport: viewport,
            onTextEdit: onTextEdit,
            onSlashCommand: onSlashCommand
        )
    }
}

final class EditorContainerView: NSView {
    let scrollView: NSScrollView
    let textView: EditorTextView

    var onViewportSizeChanged: (() -> Void)?

    private let preferredWidthConstraint: NSLayoutConstraint
    private var lastViewportSize = NSSize.zero
    private var hasRequestedInitialFocus = false

    init(textView: EditorTextView) {
        self.textView = textView
        scrollView = NSScrollView(frame: .zero)
        preferredWidthConstraint = scrollView.widthAnchor.constraint(equalToConstant: 0)
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
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
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
        preferredWidthConstraint.priority = .init(999)
        let fillWhenNarrowConstraint = scrollView.widthAnchor.constraint(equalTo: widthAnchor)
        fillWhenNarrowConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scrollView.centerXAnchor.constraint(equalTo: centerXAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            preferredWidthConstraint,
            fillWhenNarrowConstraint
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EditorContainerView is created programmatically")
    }

    override func layout() {
        super.layout()

        let viewportSize = scrollView.contentSize
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
        onViewportSizeChanged?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !hasRequestedInitialFocus else { return }
        hasRequestedInitialFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            // A palette or another text field may have claimed focus while
            // SwiftUI attached this editor during the same update.
            if let responder = window.firstResponder as? NSTextView,
               responder !== self.textView { return }
            window.makeFirstResponder(self.textView)
        }
    }

    func apply(configuration: EditorConfiguration) {
        textView.applyEditorConfiguration(configuration)
        let font = Typography.font(size: configuration.resolvedFontSize)
        let textWidth = Typography.characterAdvance(for: font)
            * CGFloat(configuration.resolvedMeasure)
        preferredWidthConstraint.constant = ceil(
            textWidth + (Metrics.horizontalPadding * 2)
        )
        needsLayout = true
    }
}
