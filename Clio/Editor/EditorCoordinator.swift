import AppKit
import SwiftUI

@MainActor
final class EditorCoordinator: NSObject, NSTextViewDelegate {
    private var viewport: Binding<EditorViewportState>?
    private var configuration: EditorConfiguration
    private var onTextEdit: @MainActor (MarkdownTextEdit) -> Void
    private var onSlashCommand: (@MainActor (SlashCommandPresentation) -> Void)?
    private var isRestoringLiteralSlash = false
    private let minimap: EditorMinimapModel?
    private weak var surface: EditorContainerView?

    private let typewriterScroller = TypewriterScroller()
    private let focusDimmer = FocusDimmer()
    private var markdownEngine = IncrementalMarkdownHighlighter()
    private let markdownHighlighter = MarkdownTextKitHighlighter()
    private let markdownEditingController = MarkdownEditingController()
    private var isApplyingExternalUpdate = false
    private var isApplyingHighlight = false
    private var isChangingText = false
    private var isHandlingKeyEvent = false
    private var hasAppliedConfiguration = false
    private var pendingMarkdownEdit: MarkdownTextEdit?
    private var markdownTask: Task<Void, Never>?
    private var markdownEditTask: Task<Void, Never>?
    private var pendingHighlightEdits: [MarkdownTextEdit] = []
    private var markdownEngineEpoch: UInt64 = 0
    private var markdownRequestSequence: UInt64 = 0
    private var renderedContentGeneration: BufferGeneration?
    private var pendingEditorRevisionAdvances: UInt64 = 0
    private(set) var externalBufferReplacementCount = 0
    private(set) var acceptedEditorMutationCount = 0
    private var hasRestoredViewport = false
    private var isApplyingViewport = false
    private var lastKnownViewport: EditorViewportState?
    private var boundsObserver: NSObjectProtocol?

    init(
        configuration: EditorConfiguration,
        viewport: Binding<EditorViewportState>? = nil,
        onTextEdit: @escaping @MainActor (MarkdownTextEdit) -> Void,
        onSlashCommand: (@MainActor (SlashCommandPresentation) -> Void)? = nil,
        minimap: EditorMinimapModel? = nil
    ) {
        self.viewport = viewport
        self.configuration = configuration
        self.onTextEdit = onTextEdit
        self.onSlashCommand = onSlashCommand
        self.minimap = minimap
    }

    deinit {
        markdownTask?.cancel()
        markdownEditTask?.cancel()
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    func attach(to surface: EditorContainerView) {
        self.surface = surface
        minimap?.navigate = { [weak self, weak surface] offset in
            guard let self, let surface else { return }
            self.typewriterScroller.suspendUntilNextEdit()
            let range = NSRange(location: min(max(0, offset), surface.textView.string.utf16.count), length: 0)
            surface.textView.scrollRangeToVisible(range)
            if let window = surface.textView.window {
                let screen = surface.textView.firstRect(forCharacterRange: range, actualRange: nil)
                let rect = surface.textView.convert(window.convertFromScreen(screen), from: nil)
                let scroll = surface.scrollView
                let clip = scroll.contentView
                let minimum = -scroll.contentInsets.top
                let maximum = max(minimum, surface.textView.bounds.height - clip.bounds.height + scroll.contentInsets.bottom)
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(maximum, max(minimum, rect.minY - 8))))
                scroll.reflectScrolledClipView(clip)
            }
            self.captureViewport()
            self.minimap?.visibleOffset = range.location
        }
        surface.textView.delegate = self
        surface.textView.onUserScroll = { [weak self] in
            self?.typewriterScroller.suspendUntilNextEdit()
            self?.captureViewport()
        }
        surface.textView.onKeyEventBegan = { [weak self] in
            self?.isHandlingKeyEvent = true
        }
        surface.textView.onKeyEventEnded = { [weak self] in
            self?.isHandlingKeyEvent = false
            self?.isChangingText = false
            self?.scheduleSettledTypewriterScroll()
        }
        surface.textView.onMarkdownAction = { [weak self, weak textView = surface.textView] action in
            guard let self, let textView else { return false }
            return self.markdownEditingController.perform(action, in: textView)
        }
        surface.onViewportSizeChanged = { [weak self, weak surface] in
            guard let self, let surface else { return }
            self.minimap?.reservesNativeScroller = surface.reservesNativeScroller
            self.typewriterScroller.updateViewportInsets(
                in: surface,
                configuration: self.configuration
            )
            self.scheduleSettledTypewriterScroll()
        }
        surface.scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: surface.scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.captureViewport()
            }
        }
    }

    func update(
        text: String,
        contentGeneration: BufferGeneration,
        configuration: EditorConfiguration,
        viewport: Binding<EditorViewportState>? = nil,
        onTextEdit: @escaping @MainActor (MarkdownTextEdit) -> Void,
        onSlashCommand: (@MainActor (SlashCommandPresentation) -> Void)? = nil
    ) {
        self.onTextEdit = onTextEdit
        self.viewport = viewport
        self.onSlashCommand = onSlashCommand
        guard let surface else { return }

        let configurationChanged = self.configuration != configuration
        self.configuration = configuration

        if configurationChanged || !hasAppliedConfiguration {
            focusDimmer.clear(in: surface.textView)
            surface.apply(configuration: configuration)
            surface.textView.applyBaseAttributes(for: configuration)
            hasAppliedConfiguration = true
            if configurationChanged {
                markdownHighlighter.reapply(
                    to: surface.textView,
                    configuration: configuration
                )
            }
        }

        if let renderedContentGeneration {
            if contentGeneration != renderedContentGeneration {
                if contentGeneration.bufferID != renderedContentGeneration.bufferID {
                    typewriterScroller.suspendUntilNextEdit()
                    surface.textView.undoManager?.removeAllActions()
                    hasRestoredViewport = false
                    lastKnownViewport = nil
                }
                let expectedEditorRevision = renderedContentGeneration.revision
                    &+ pendingEditorRevisionAdvances
                if contentGeneration.bufferID == renderedContentGeneration.bufferID,
                   pendingEditorRevisionAdvances > 0,
                   contentGeneration.revision > renderedContentGeneration.revision,
                   contentGeneration.revision <= expectedEditorRevision {
                    pendingEditorRevisionAdvances -= contentGeneration.revision
                        - renderedContentGeneration.revision
                } else {
                    replaceEditorText(with: text, in: surface.textView)
                    pendingEditorRevisionAdvances = 0
                }
                self.renderedContentGeneration = contentGeneration
            }
        } else {
            replaceEditorText(with: text, in: surface.textView)
            renderedContentGeneration = contentGeneration
        }
        typewriterScroller.updateViewportInsets(in: surface, configuration: configuration)
        focusDimmer.apply(to: surface.textView, configuration: configuration)
        applyBoundViewportIfNeeded()
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingExternalUpdate, !isApplyingHighlight,
              let textView = notification.object as? NSTextView else { return }

        guard let edit = pendingMarkdownEdit else {
            // NSTextView character mutations are preceded by
            // shouldChangeTextIn. Refuse an untracked mutation rather than
            // synchronously snapshotting a potentially 50 MiB buffer.
            return
        }
        pendingMarkdownEdit = nil
        pendingEditorRevisionAdvances &+= 1
        acceptedEditorMutationCount += 1
        onTextEdit(edit)
        scheduleMarkdownEdit(edit)

        typewriterScroller.resumeAfterEdit()
        focusDimmer.apply(to: textView, configuration: configuration)
        scheduleSettledTypewriterScroll()
        isChangingText = false
        captureViewport()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isApplyingExternalUpdate,
              let textView = notification.object as? NSTextView else { return }

        focusDimmer.apply(to: textView, configuration: configuration)
        if isHandlingKeyEvent { scheduleSettledTypewriterScroll() }
        captureViewport()
    }

    private var settledScrollScheduled = false

    private func scheduleSettledTypewriterScroll() {
        guard !settledScrollScheduled else { return }
        settledScrollScheduled = true
        // textDidChange can precede the final insertion selection and TextKit's
        // extra-line layout. Reconcile once after the entire native edit event.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.settledScrollScheduled = false
            guard let surface = self.surface else { return }
            surface.layoutSubtreeIfNeeded()
            self.typewriterScroller.scrollCaretToAnchor(
                in: surface, configuration: self.configuration, animated: false
            )
            self.captureViewport()
        }
    }

    func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        let replacement = replacementString ?? ""
        if onSlashCommand != nil, !isRestoringLiteralSlash, Self.isInlineSlashTrigger(
            in: textView.string,
            range: affectedCharRange,
            replacement: replacement,
            hasMarkedText: textView.hasMarkedText()
        ) {
            pendingMarkdownEdit = nil
            isChangingText = false
            var anchor: CGRect?
            if Self.isEmptySlashLine(in: textView.string, range: affectedCharRange),
               let window = textView.window, let content = window.contentView {
                let screenRect = textView.firstRect(forCharacterRange: affectedCharRange, actualRange: nil)
                let rect = content.convert(window.convertFromScreen(screenRect), from: nil)
                anchor = CGRect(x: rect.minX, y: content.bounds.maxY - rect.maxY,
                                width: max(1, rect.width), height: rect.height)
            }
            let presentation = SlashCommandPresentation(anchor: anchor) { [weak self, weak textView] literal in
                guard let self, let textView else { return }
                self.isRestoringLiteralSlash = true
                defer { self.isRestoringLiteralSlash = false }
                textView.insertText(literal, replacementRange: affectedCharRange)
            }
            DispatchQueue.main.async { [weak self] in
                self?.onSlashCommand?(presentation)
            }
            return false
        }

        isChangingText = true
        focusDimmer.clear(in: textView)
        pendingMarkdownEdit = MarkdownTextEdit(
            replacedRange: affectedCharRange.utf16,
            replacement: replacementString ?? ""
        )
        return true
    }

    static func isInlineSlashTrigger(
        in source: String,
        range: NSRange,
        replacement: String,
        hasMarkedText: Bool = false
    ) -> Bool {
        guard !hasMarkedText,
              replacement == "/",
              range.length >= 0 else { return false }
        let source = source as NSString
        guard range.location >= 0, range.location <= source.length,
              range.length <= source.length - range.location else { return false }
        return true
    }

    static func isEmptySlashLine(in source: String, range: NSRange) -> Bool {
        let source = source as NSString
        guard range.length == 0, range.location >= 0, range.location <= source.length else { return false }
        let line = source.lineRange(for: range)
        return source.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func replaceEditorText(with newText: String, in textView: EditorTextView) {
        externalBufferReplacementCount += 1
        let selection = textView.selectedRange()
        let visibleOrigin = textView.enclosingScrollView?.contentView.bounds.origin
        let undoWasEnabled = textView.allowsUndo

        isApplyingExternalUpdate = true
        focusDimmer.clear(in: textView)
        textView.allowsUndo = false
        if let textStorage = textView.textStorage {
            textStorage.replaceCharacters(
                in: NSRange(location: 0, length: textStorage.length),
                with: newText
            )
        } else {
            textView.string = newText
        }
        textView.applyBaseAttributes(for: configuration)

        let length = textView.textStorage?.length ?? (newText as NSString).length
        let location = min(selection.location, length)
        let selectedLength = min(selection.length, length - location)
        textView.setSelectedRange(NSRange(location: location, length: selectedLength))
        textView.allowsUndo = undoWasEnabled
        textView.undoManager?.removeAllActions()

        if let visibleOrigin, let scrollView = textView.enclosingScrollView {
            scrollView.contentView.scroll(to: visibleOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        isApplyingExternalUpdate = false
        pendingMarkdownEdit = nil
        scheduleMarkdownReplacement(source: newText)
    }

    private func scheduleMarkdownReplacement(source: String) {
        minimap?.snapshot = .empty
        markdownTask?.cancel()
        markdownEditTask?.cancel()
        markdownEditTask = nil
        pendingHighlightEdits.removeAll(keepingCapacity: true)
        markdownEngineEpoch &+= 1
        markdownEngine = IncrementalMarkdownHighlighter()
        markdownRequestSequence &+= 1
        let requestSequence = markdownRequestSequence
        let engine = markdownEngine
        markdownTask = Task { [weak self] in
            do {
                let update = try await engine.update(source: source)
                try Task.checkCancellation()
                self?.applyMarkdownUpdate(update, requestSequence: requestSequence)
            } catch is CancellationError {
                return
            } catch {
                self?.clearMarkdownHighlighting(requestSequence: requestSequence)
            }
        }
    }

    /// Local edits form a serial delta stream. Older highlights may be stale
    /// and are not painted, but every delta is applied to the actor-owned
    /// source mirror in order, so rapid typing never requires a fresh full
    /// NSTextView snapshot.
    private func scheduleMarkdownEdit(_ edit: MarkdownTextEdit) {
        enqueueHighlightEdit(edit)
        markdownRequestSequence &+= 1
        guard markdownEditTask == nil else { return }

        let predecessor = markdownTask
        let engineEpoch = markdownEngineEpoch
        let engine = markdownEngine
        markdownEditTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(8))
            } catch {
                return
            }
            await predecessor?.value

            guard let self else { return }
            while self.markdownEngineEpoch == engineEpoch,
                  !self.pendingHighlightEdits.isEmpty {
                let edits = self.pendingHighlightEdits
                self.pendingHighlightEdits.removeAll(keepingCapacity: true)
                let requestSequence = self.markdownRequestSequence
                do {
                    try Task.checkCancellation()
                    let update = try await engine.update(edits: edits)
                    try Task.checkCancellation()
                    self.applyMarkdownUpdate(
                        update,
                        requestSequence: requestSequence
                    )
                } catch is CancellationError {
                    return
                } catch {
                    if self.markdownEngineEpoch == engineEpoch {
                        self.pendingHighlightEdits.removeAll(keepingCapacity: true)
                        self.markdownEditTask = nil
                        self.clearMarkdownHighlighting(
                            requestSequence: self.markdownRequestSequence
                        )
                    }
                    return
                }
                await Task.yield()
            }
            guard self.markdownEngineEpoch == engineEpoch else { return }
            self.markdownEditTask = nil
        }
    }

    private func enqueueHighlightEdit(_ edit: MarkdownTextEdit) {
        if let index = pendingHighlightEdits.indices.last {
            let previous = pendingHighlightEdits[index]
            let previousReplacementLength = (previous.replacement as NSString).length
            if previous.replacedRange.length == 0,
               edit.replacedRange.length == 0,
               edit.replacedRange.location
                    == previous.replacedRange.location + previousReplacementLength {
                pendingHighlightEdits[index] = MarkdownTextEdit(
                    replacedRange: previous.replacedRange,
                    replacement: previous.replacement + edit.replacement
                )
                return
            }
        }
        pendingHighlightEdits.append(edit)
    }

    private func applyMarkdownUpdate(
        _ update: MarkdownHighlightUpdate,
        requestSequence: UInt64
    ) {
        guard let surface,
              markdownRequestSequence == requestSequence,
              surface.textView.textStorage?.length == update.sourceUTF16Length else {
            return
        }
        isApplyingHighlight = true
        minimap?.snapshot = update.minimap
        markdownHighlighter.apply(
            update,
            to: surface.textView,
            configuration: configuration
        )
        isApplyingHighlight = false
        focusDimmer.apply(to: surface.textView, configuration: configuration)
    }

    private func clearMarkdownHighlighting(requestSequence: UInt64) {
        guard markdownRequestSequence == requestSequence, let surface else { return }
        minimap?.snapshot = .empty
        isApplyingHighlight = true
        markdownHighlighter.clear(
            in: surface.textView,
            configuration: configuration
        )
        isApplyingHighlight = false
    }

    private func applyBoundViewportIfNeeded() {
        guard let surface,
              let state = viewport?.wrappedValue else { return }
        if hasRestoredViewport, state == lastKnownViewport { return }
        hasRestoredViewport = true
        isApplyingViewport = true

        let length = (surface.textView.string as NSString).length
        let clamped = state.clamped(toUTF16Length: length)
        lastKnownViewport = clamped
        surface.textView.setSelectedRange(
            NSRange(
                location: clamped.selection.location,
                length: clamped.selection.length
            )
        )
        surface.textView.scrollRangeToVisible(
            NSRange(location: clamped.topVisibleUTF16Offset, length: 0)
        )

        DispatchQueue.main.async { [weak self, weak surface] in
            guard let self, let surface else { return }
            if clamped.fractionalYOffset > 0 {
                let font = surface.textView.font
                    ?? Typography.font(size: self.configuration.resolvedFontSize, name: self.configuration.fontName)
                let lineHeight = surface.textView.layoutManager?
                    .defaultLineHeight(for: font)
                    ?? font.boundingRectForFont.height
                var point = surface.scrollView.contentView.bounds.origin
                point.y += lineHeight * clamped.fractionalYOffset
                surface.scrollView.contentView.scroll(to: point)
                surface.scrollView.reflectScrolledClipView(
                    surface.scrollView.contentView
                )
            }
            self.isApplyingViewport = false
            self.captureViewport()
        }
    }

    private func captureViewport() {
        guard !isApplyingViewport,
              !isApplyingExternalUpdate,
              let surface else { return }
        let textView = surface.textView
        let length = (textView.string as NSString).length
        let selection = textView.selectedRange()
        let visibleRect = surface.scrollView.documentVisibleRect
        let insertionPoint = NSPoint(
            x: textView.textContainerInset.width,
            y: visibleRect.minY + textView.textContainerInset.height
        )
        let topOffset = min(
            max(0, textView.characterIndexForInsertion(at: insertionPoint)),
            length
        )
        minimap?.visibleOffset = topOffset
        guard let viewport else { return }
        let font = textView.font
            ?? Typography.font(size: configuration.resolvedFontSize, name: configuration.fontName)
        let lineHeight = max(
            1,
            textView.layoutManager?.defaultLineHeight(for: font)
                ?? font.boundingRectForFont.height
        )
        let clippedLineHeight = visibleRect.minY
            .truncatingRemainder(dividingBy: lineHeight)
        let fractionalOffset = min(
            max(0, Double(clippedLineHeight / lineHeight)),
            1
        )
        let next = EditorViewportState(
            selection: UTF16Range(
                location: min(selection.location, length),
                length: min(selection.length, max(0, length - min(selection.location, length)))
            ),
            topVisibleUTF16Offset: topOffset,
            fractionalYOffset: fractionalOffset
        )
        if viewport.wrappedValue != next {
            lastKnownViewport = next
            viewport.wrappedValue = next
        } else {
            lastKnownViewport = next
        }
    }
}

private extension NSRange {
    var utf16: UTF16Range { UTF16Range(location: location, length: length) }
}
