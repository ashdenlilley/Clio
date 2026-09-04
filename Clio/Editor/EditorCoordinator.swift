import AppKit
import SwiftUI

final class EditorCoordinator: NSObject, NSTextViewDelegate {
    private var text: Binding<String>
    private var viewport: Binding<EditorViewportState>?
    private var configuration: EditorConfiguration
    private var onTextEdit: ((String, EditorTextEdit?) -> Void)?
    private var onSlashCommand: (() -> Void)?
    private weak var surface: EditorContainerView?

    private let typewriterScroller = TypewriterScroller()
    private let focusDimmer = FocusDimmer()
    private var isApplyingExternalUpdate = false
    private var isChangingText = false
    private var isHandlingKeyEvent = false
    private var hasAppliedConfiguration = false
    private var hasRestoredViewport = false
    private var isApplyingViewport = false
    private var lastKnownViewport: EditorViewportState?
    private var pendingTextEdit: EditorTextEdit?
    private var boundsObserver: NSObjectProtocol?

    init(
        text: Binding<String>,
        viewport: Binding<EditorViewportState>? = nil,
        configuration: EditorConfiguration,
        onTextEdit: ((String, EditorTextEdit?) -> Void)? = nil,
        onSlashCommand: (() -> Void)? = nil
    ) {
        self.text = text
        self.viewport = viewport
        self.configuration = configuration
        self.onTextEdit = onTextEdit
        self.onSlashCommand = onSlashCommand
    }

    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    func attach(to surface: EditorContainerView) {
        self.surface = surface
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
        }
        surface.onViewportSizeChanged = { [weak self, weak surface] in
            guard let self, let surface else { return }
            self.typewriterScroller.updateViewportInsets(
                in: surface,
                configuration: self.configuration
            )
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
        text: Binding<String>,
        viewport: Binding<EditorViewportState>? = nil,
        configuration: EditorConfiguration,
        onTextEdit: ((String, EditorTextEdit?) -> Void)? = nil,
        onSlashCommand: (() -> Void)? = nil
    ) {
        self.text = text
        self.viewport = viewport
        self.onTextEdit = onTextEdit
        self.onSlashCommand = onSlashCommand
        guard let surface else { return }

        let configurationChanged = self.configuration != configuration
        self.configuration = configuration

        if configurationChanged || !hasAppliedConfiguration {
            focusDimmer.clear(in: surface.textView)
            surface.apply(configuration: configuration)
            surface.textView.applyBaseAttributes(for: configuration)
            hasAppliedConfiguration = true
        }

        replaceEditorTextIfNeeded(with: text.wrappedValue, in: surface.textView)
        typewriterScroller.updateViewportInsets(in: surface, configuration: configuration)
        focusDimmer.apply(to: surface.textView, configuration: configuration)
        applyBoundViewportIfNeeded()
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingExternalUpdate,
              let textView = notification.object as? NSTextView else { return }

        let newText = textView.string
        if let onTextEdit {
            onTextEdit(newText, pendingTextEdit)
        } else if text.wrappedValue != newText {
            text.wrappedValue = newText
        }
        pendingTextEdit = nil

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
        captureViewport()
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
        captureViewport()
    }

    func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        let replacement = replacementString ?? ""
        if Self.isInlineSlashTrigger(
            in: textView.string,
            range: affectedCharRange,
            replacement: replacement,
            hasMarkedText: textView.hasMarkedText()
        ) {
            pendingTextEdit = nil
            isChangingText = false
            DispatchQueue.main.async { [weak self] in
                self?.onSlashCommand?()
            }
            return false
        }

        isChangingText = true
        pendingTextEdit = EditorTextEdit(
            replacedRange: UTF16Range(
                location: affectedCharRange.location,
                length: affectedCharRange.length
            ),
            replacement: replacement
        )
        focusDimmer.clear(in: textView)
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
              range.length == 0 else { return false }
        let source = source as NSString
        guard range.location >= 0, range.location <= source.length else { return false }
        guard range.location > 0 else { return true }
        let preceding = source.character(at: range.location - 1)
        return preceding == 0x0A || preceding == 0x0D
    }

    private func replaceEditorTextIfNeeded(with newText: String, in textView: EditorTextView) {
        guard textView.string != newText else { return }

        let selection = textView.selectedRange()
        let visibleOrigin = textView.enclosingScrollView?.contentView.bounds.origin
        let undoWasEnabled = textView.allowsUndo

        isApplyingExternalUpdate = true
        pendingTextEdit = nil
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
                    ?? Typography.font(size: self.configuration.resolvedFontSize)
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
              let surface,
              let viewport else { return }
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
        let font = textView.font
            ?? Typography.font(size: configuration.resolvedFontSize)
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
