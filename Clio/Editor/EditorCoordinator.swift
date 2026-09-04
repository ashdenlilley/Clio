import AppKit

@MainActor
final class EditorCoordinator: NSObject, NSTextViewDelegate {
    private var configuration: EditorConfiguration
    private var onTextEdit: @MainActor (MarkdownTextEdit) -> Void
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

    init(
        configuration: EditorConfiguration,
        onTextEdit: @escaping @MainActor (MarkdownTextEdit) -> Void
    ) {
        self.configuration = configuration
        self.onTextEdit = onTextEdit
    }

    func attach(to surface: EditorContainerView) {
        self.surface = surface
        surface.textView.delegate = self
        surface.textView.onUserScroll = { [weak self] in
            self?.typewriterScroller.suspendUntilNextEdit()
        }
        surface.textView.onKeyEventBegan = { [weak self] in
            self?.isHandlingKeyEvent = true
        }
        surface.textView.onKeyEventEnded = { [weak self] in
            self?.isHandlingKeyEvent = false
            self?.isChangingText = false
        }
        surface.textView.onMarkdownAction = { [weak self, weak textView = surface.textView] action in
            guard let self, let textView else { return false }
            return self.markdownEditingController.perform(action, in: textView)
        }
        surface.onViewportSizeChanged = { [weak self, weak surface] in
            guard let self, let surface else { return }
            self.typewriterScroller.updateViewportInsets(
                in: surface,
                configuration: self.configuration
            )
        }
    }

    func update(
        text: String,
        contentGeneration: BufferGeneration,
        configuration: EditorConfiguration,
        onTextEdit: @escaping @MainActor (MarkdownTextEdit) -> Void
    ) {
        self.onTextEdit = onTextEdit
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
        if let surface {
            typewriterScroller.scrollCaretToAnchor(
                in: surface,
                configuration: configuration,
                animated: false
            )
        }
        isChangingText = false
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isApplyingExternalUpdate,
              let textView = notification.object as? NSTextView else { return }

        focusDimmer.apply(to: textView, configuration: configuration)
        guard let surface else { return }
        typewriterScroller.scrollCaretToAnchor(
            in: surface,
            configuration: configuration,
            animated: isHandlingKeyEvent && !isChangingText
        )
    }

    func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        isChangingText = true
        focusDimmer.clear(in: textView)
        pendingMarkdownEdit = MarkdownTextEdit(
            replacedRange: affectedCharRange.utf16,
            replacement: replacementString ?? ""
        )
        return true
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
        isApplyingHighlight = true
        markdownHighlighter.clear(
            in: surface.textView,
            configuration: configuration
        )
        isApplyingHighlight = false
    }

    deinit {
        markdownTask?.cancel()
        markdownEditTask?.cancel()
    }
}

private extension NSRange {
    var utf16: UTF16Range { UTF16Range(location: location, length: length) }
}
