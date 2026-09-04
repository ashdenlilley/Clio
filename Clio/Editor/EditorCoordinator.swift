import AppKit
import SwiftUI

@MainActor
final class EditorCoordinator: NSObject, NSTextViewDelegate {
    private var text: Binding<String>
    private var configuration: EditorConfiguration
    private weak var surface: EditorContainerView?

    private let typewriterScroller = TypewriterScroller()
    private let focusDimmer = FocusDimmer()
    private let markdownEngine = IncrementalMarkdownHighlighter()
    private let markdownHighlighter = MarkdownTextKitHighlighter()
    private let markdownEditingController = MarkdownEditingController()
    private var isApplyingExternalUpdate = false
    private var isApplyingHighlight = false
    private var isChangingText = false
    private var isHandlingKeyEvent = false
    private var hasAppliedConfiguration = false
    private var pendingMarkdownEdit: MarkdownTextEdit?
    private var markdownTask: Task<Void, Never>?
    private var markdownRequestSequence: UInt64 = 0

    init(text: Binding<String>, configuration: EditorConfiguration) {
        self.text = text
        self.configuration = configuration
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

    func update(text: Binding<String>, configuration: EditorConfiguration) {
        self.text = text
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

        replaceEditorTextIfNeeded(with: text.wrappedValue, in: surface.textView)
        if markdownHighlighter.lastUpdate == nil {
            scheduleMarkdownUpdate(source: surface.textView.string, edit: nil)
        }
        typewriterScroller.updateViewportInsets(in: surface, configuration: configuration)
        focusDimmer.apply(to: surface.textView, configuration: configuration)
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingExternalUpdate, !isApplyingHighlight,
              let textView = notification.object as? NSTextView else { return }

        let newText = textView.string
        if text.wrappedValue != newText {
            text.wrappedValue = newText
        }
        let edit = pendingMarkdownEdit
        pendingMarkdownEdit = nil
        scheduleMarkdownUpdate(source: newText, edit: edit)

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

    private func replaceEditorTextIfNeeded(with newText: String, in textView: EditorTextView) {
        guard textView.string != newText else { return }

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

        let length = (newText as NSString).length
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
        scheduleMarkdownUpdate(source: newText, edit: nil)
    }

    private func scheduleMarkdownUpdate(source: String, edit: MarkdownTextEdit?) {
        markdownTask?.cancel()
        markdownRequestSequence &+= 1
        let requestSequence = markdownRequestSequence
        let engine = markdownEngine
        markdownTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(18))
                let update = try await engine.update(source: source, edit: edit)
                try Task.checkCancellation()
                guard let self, let surface = self.surface,
                      self.markdownRequestSequence == requestSequence,
                      (surface.textView.string as NSString).length == update.sourceUTF16Length else {
                    return
                }
                self.isApplyingHighlight = true
                self.markdownHighlighter.apply(
                    update,
                    to: surface.textView,
                    configuration: self.configuration
                )
                self.isApplyingHighlight = false
                self.focusDimmer.apply(
                    to: surface.textView,
                    configuration: self.configuration
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self, let surface = self.surface else { return }
                self.isApplyingHighlight = true
                self.markdownHighlighter.clear(
                    in: surface.textView,
                    configuration: self.configuration
                )
                self.isApplyingHighlight = false
            }
        }
    }

    deinit {
        markdownTask?.cancel()
    }
}

private extension NSRange {
    var utf16: UTF16Range { UTF16Range(location: location, length: length) }
}
