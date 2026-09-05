import AppKit
import QuartzCore

/// Keeps the insertion point near a stable vertical anchor while preserving
/// ordinary manual scrolling until the writer types again.
final class TypewriterScroller {
    private var isSuspendedByUserScroll = false
    private var shouldEaseReturn = false
    private var returnTimer: Timer?
    private var returnStartedAt: CFTimeInterval = 0
    private var returnStartY: CGFloat = 0
    private var returnTargetY: CGFloat = 0
    static let returnDuration: CFTimeInterval = 2

    deinit { returnTimer?.invalidate() }

    func suspendUntilNextEdit() {
        isSuspendedByUserScroll = true
        shouldEaseReturn = false
        returnTimer?.invalidate()
        returnTimer = nil
    }

    func resumeAfterEdit() {
        if isSuspendedByUserScroll { shouldEaseReturn = true }
        isSuspendedByUserScroll = false
    }

    func updateViewportInsets(
        in surface: EditorContainerView,
        configuration: EditorConfiguration
    ) {
        let scrollView = surface.scrollView
        guard configuration.isTypewriterScrollingEnabled else {
            returnTimer?.invalidate()
            returnTimer = nil
            shouldEaseReturn = false
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
        // Layout of the extra final line can precede NSTextView's frame-size
        // update. Reserve its actual extent before clamping the scroll target;
        // otherwise repeated Return presses hit yesterday's document bottom.
        let requiredHeight = caretRect.maxY + surface.textView.textContainerInset.height
        if requiredHeight > surface.textView.frame.height {
            surface.textView.setFrameSize(NSSize(width: surface.textView.frame.width, height: requiredHeight))
        }
        let documentHeight = surface.textView.bounds.height
        let maximumY = max(
            minimumY,
            documentHeight - viewportHeight + scrollView.contentInsets.bottom
        )
        let targetY = min(max(requestedY, minimumY), maximumY)
        let target = NSPoint(x: clipView.bounds.origin.x, y: targetY)

        if returnTimer != nil {
            // Continued typing retargets the existing return, not a fresh two
            // seconds per keystroke. Manual scroll cancels the timer immediately.
            returnTargetY = targetY
            return
        }

        let easeReturn = shouldEaseReturn
        shouldEaseReturn = false
        guard abs(clipView.bounds.origin.y - targetY) > 0.5 else { return }

        if easeReturn && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            returnStartedAt = CACurrentMediaTime()
            returnStartY = clipView.bounds.minY
            returnTargetY = targetY
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self, weak scrollView] _ in
                MainActor.assumeIsolated {
                    guard let self, let scrollView else { return }
                    let progress = min(1, (CACurrentMediaTime() - self.returnStartedAt) / Self.returnDuration)
                    let eased = progress * progress * (3 - 2 * progress)
                    let clip = scrollView.contentView
                    clip.scroll(to: NSPoint(x: clip.bounds.minX,
                        y: self.returnStartY + (self.returnTargetY - self.returnStartY) * eased))
                    scrollView.reflectScrolledClipView(clip)
                    if progress >= 1 { self.returnTimer?.invalidate(); self.returnTimer = nil }
                }
            }
            returnTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            return
        }

        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
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
