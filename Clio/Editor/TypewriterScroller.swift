import AppKit
import QuartzCore

/// Keeps the insertion point near a stable vertical anchor while preserving
/// ordinary manual scrolling until the writer types again.
final class TypewriterScroller {
    private var isSuspendedByUserScroll = false

    func suspendUntilNextEdit() {
        isSuspendedByUserScroll = true
    }

    func resumeAfterEdit() {
        isSuspendedByUserScroll = false
    }

    func updateViewportInsets(
        in surface: EditorContainerView,
        configuration: EditorConfiguration
    ) {
        let scrollView = surface.scrollView
        guard configuration.isTypewriterScrollingEnabled else {
            let zeroInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            if !Self.nearlyEqual(scrollView.contentInsets, zeroInsets) {
                scrollView.contentInsets = zeroInsets
            }
            return
        }

        let viewportHeight = scrollView.contentView.bounds.height
        guard viewportHeight > 0 else { return }

        // The text view already supplies the fixed 64pt editor padding. Extra
        // scroll insets make both the first and final line able to reach the
        // asymmetric typewriter anchor without altering the source or layout.
        let anchor = configuration.resolvedTypewriterAnchor
        let top = max(0, viewportHeight * anchor - Metrics.verticalPadding)
        let bottom = max(0, viewportHeight * (1 - anchor) - Metrics.verticalPadding)
        let insets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)

        if !Self.nearlyEqual(scrollView.contentInsets, insets) {
            scrollView.contentInsets = insets
        }
    }

    func scrollCaretToAnchor(
        in surface: EditorContainerView,
        configuration: EditorConfiguration,
        animated: Bool
    ) {
        guard configuration.isTypewriterScrollingEnabled,
              !isSuspendedByUserScroll,
              let caretRect = caretRect(in: surface.textView) else { return }

        updateViewportInsets(in: surface, configuration: configuration)

        let scrollView = surface.scrollView
        let clipView = scrollView.contentView
        let viewportHeight = clipView.bounds.height
        guard viewportHeight > 0 else { return }

        let requestedY = caretRect.midY
            - (viewportHeight * configuration.resolvedTypewriterAnchor)
        let minimumY = -scrollView.contentInsets.top
        let documentHeight = surface.textView.bounds.height
        let maximumY = max(
            minimumY,
            documentHeight - viewportHeight + scrollView.contentInsets.bottom
        )
        let targetY = min(max(requestedY, minimumY), maximumY)
        let target = NSPoint(x: clipView.bounds.origin.x, y: targetY)

        guard abs(clipView.bounds.origin.y - targetY) > 0.5 else { return }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.09
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clipView.animator().setBoundsOrigin(target)
            } completionHandler: {
                scrollView.reflectScrolledClipView(clipView)
            }
        } else {
            clipView.scroll(to: target)
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    private func caretRect(in textView: NSTextView) -> NSRect? {
        guard textView.selectedRange().length == 0,
              let contentStorage = textView.textContentStorage,
              let layoutManager = textView.textLayoutManager else { return nil }

        let offset = min(textView.selectedRange().location, (textView.string as NSString).length)
        let documentRange = contentStorage.documentRange
        guard let location = contentStorage.location(
            documentRange.location,
            offsetBy: offset
        ) else { return nil }

        let textRange = NSTextRange(location: location)
        layoutManager.ensureLayout(for: textRange)

        var result: NSRect?
        layoutManager.enumerateTextSegments(
            in: textRange,
            type: .selection,
            options: [.rangeNotRequired]
        ) { _, frame, _, _ in
            result = frame.offsetBy(
                dx: textView.textContainerOrigin.x,
                dy: textView.textContainerOrigin.y
            )
            return false
        }

        if let result { return result }

        // TextKit can have no segment ready for an empty final paragraph. The
        // text-input API still provides the correct insertion rectangle.
        guard let window = textView.window else { return nil }
        var actualRange = NSRange()
        let screenRect = textView.firstRect(
            forCharacterRange: NSRange(location: offset, length: 0),
            actualRange: &actualRange
        )
        let windowRect = window.convertFromScreen(screenRect)
        return textView.convert(windowRect, from: nil)
    }

    private static func nearlyEqual(_ lhs: NSEdgeInsets, _ rhs: NSEdgeInsets) -> Bool {
        abs(lhs.top - rhs.top) < 0.5
            && abs(lhs.left - rhs.left) < 0.5
            && abs(lhs.bottom - rhs.bottom) < 0.5
            && abs(lhs.right - rhs.right) < 0.5
    }
}
