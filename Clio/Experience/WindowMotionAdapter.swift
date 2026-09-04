import AppKit
import Observation
import QuartzCore

/// One clock and one driver per editor window. Idle windows schedule only their
/// next semantic deadline; animation frames never start SwiftUI animations.
@MainActor @Observable
final class WindowMotionAdapter: NSObject {
    let chrome: ChromeMotionController
    let surfaces: TransientSurfaceMotionController
    private(set) var revision: UInt64 = 0
    @ObservationIgnored private let clock: MotionClock
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var displayTarget: WeakMotionDisplayTarget?
    @ObservationIgnored private var timerGeneration: UInt64 = 0
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var responders: [UUID: WeakMotionResponder] = [:]
    @ObservationIgnored var applyNativeChrome: (() -> Void)?
    @ObservationIgnored var sidebarIntentChanged: ((Bool) -> Void)?
    @ObservationIgnored var documentIdentity: (() -> UUID?)?
    @ObservationIgnored private var gestureTranslation = 0.0
    @ObservationIgnored private var gestureStartingProgress = 0.0
    @ObservationIgnored private var gestureVelocity = 0.0
    @ObservationIgnored private var gestureTimestamp = 0.0
    @ObservationIgnored private var trackingGesture = false
    @ObservationIgnored private var lastPresentation: MotionAdapterPresentation?

    init(sidebarVisible: Bool = true, pinned: Bool = false, clock: MotionClock = SystemMotionClock()) {
        self.clock = clock
        chrome = ChromeMotionController(clock: clock, sidebarInitiallyVisible: sidebarVisible, sidebarPinned: pinned)
        surfaces = TransientSurfaceMotionController(clock: clock)
        super.init()
    }

    var sidebarProgress: Double { _ = revision; return chrome.sidebar.presentation }
    var contextProgress: Double { _ = revision; return chrome.context.presentation }
    var titlebarProgress: Double { _ = revision; return chrome.titlebar.presentation }
    var surfaceState: TransientSurfaceMotionController { _ = revision; return surfaces }
    var preferences: MotionPreferences { _ = revision; return chrome.preferences }
    var isDrivingFrames: Bool { displayLink != nil || (timer != nil && (chrome.hasActiveTransitions || surfaces.hasActiveTransitions)) }

    func update(_ action: (ChromeMotionController) -> Void) {
        action(chrome)
        refresh()
    }

    func setPreferences(_ preferences: MotionPreferences) {
        chrome.setMotionPreferences(preferences)
        surfaces.setMotionPreferences(preferences)
        refresh()
    }

    func synchronizeSurface(_ surface: TransientSurface, presented: Bool, viewport: EditorViewportState) {
        guard surfaces.activeSurfaces.contains(surface) != presented else { return }
        chrome.noteIntentionalInteraction()
        if presented {
            let token = UUID()
            responders[token] = WeakMotionResponder(window?.firstResponder, documentIdentity: documentIdentity?())
            let snapshot = MotionFocusSnapshot(responderToken: token, viewport: viewport)
            switch surface {
            case .palette: surfaces.presentPalette(capturing: snapshot)
            case .settings: surfaces.presentSettings(capturing: snapshot)
            case .conflict: surfaces.presentConflict(capturing: snapshot)
            }
        } else {
            let snapshot: MotionFocusSnapshot?
            switch surface {
            case .palette: snapshot = surfaces.dismissPalette()
            case .settings: snapshot = surfaces.dismissSettings()
            case .conflict: snapshot = surfaces.conflictResolutionSucceeded()
            }
            if let snapshot { restore(snapshot) }
        }
        refresh()
    }

    private func restore(_ snapshot: MotionFocusSnapshot) {
        guard let responder = responders[snapshot.responderToken]?.value,
              let window else { return }
        if let view = responder as? NSView, view.window !== window { return }
        // Capture AppKit's exact selection and visible rect with the responder;
        // restoring it does not require looking up another editor by type.
        if let saved = responders[snapshot.responderToken] { saved.restoreViewport(documentIdentity: documentIdentity?()) }
        window.makeFirstResponder(responder)
    }

    func handleScroll(_ event: NSEvent) -> Bool {
        handleSidebarScroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                            precise: event.hasPreciseScrollingDeltas, phase: event.phase,
                            momentum: event.momentumPhase, inverted: event.isDirectionInvertedFromDevice,
                            timestamp: event.timestamp)
    }

    func handleSidebarScroll(deltaX: Double, deltaY: Double, precise: Bool,
                             phase: NSEvent.Phase, momentum: NSEvent.Phase,
                             inverted: Bool, timestamp: TimeInterval) -> Bool {
        guard precise, momentum.isEmpty else { return false }
        if phase.contains(.cancelled) {
            guard trackingGesture else { return false }
            trackingGesture = false
            update { $0.cancelSidebarGesture() }
            return true
        }
        if phase.contains(.ended) {
            guard trackingGesture else { return false }
            trackingGesture = false
            update { $0.endSidebarGesture(normalizedVelocity: gestureVelocity / 252) }
            return true
        }
        guard !phase.isEmpty else { return false }
        if !trackingGesture {
            guard abs(deltaX) > abs(deltaY) * 1.25,
                  abs(deltaX) > 0 else { return false }
            trackingGesture = true
            gestureTranslation = 0
            gestureTimestamp = timestamp
            chrome.beginSidebarGesture()
            gestureStartingProgress = chrome.sidebar.presentation
        }
        let delta = inverted ? deltaX : -deltaX
        gestureTranslation = min((1 - gestureStartingProgress) * 252,
                                 max(-gestureStartingProgress * 252, gestureTranslation + delta))
        gestureVelocity = delta / max(1.0 / 120, timestamp - gestureTimestamp)
        gestureTimestamp = timestamp
        chrome.updateSidebarGesture(translation: gestureTranslation, sidebarWidth: 252)
        refresh()
        return true
    }

    func refresh() {
        chrome.tick()
        surfaces.tick()
        _ = chrome.drainEvents()
        _ = surfaces.drainEvents()
        sidebarIntentChanged?(chrome.isSidebarIntendedVisible)
        let presentation = MotionAdapterPresentation(chrome: chrome, surfaces: surfaces)
        if presentation != lastPresentation {
            lastPresentation = presentation
            revision &+= 1
            applyNativeChrome?()
        }
        scheduleNextFrameOrDeadline()
        if surfaces.visualSurfaceStack.isEmpty { responders.removeAll() }
    }

    func stop() {
        timerGeneration &+= 1
        timer?.invalidate()
        timer = nil
        displayLink?.invalidate()
        displayLink = nil
        displayTarget = nil
        applyNativeChrome = nil
        window = nil
    }

    private func scheduleNextFrameOrDeadline() {
        timerGeneration &+= 1
        timer?.invalidate()
        timer = nil
        let interval: TimeInterval
        if chrome.hasActiveTransitions || surfaces.hasActiveTransitions {
            if let window {
                if displayLink == nil {
                    let target = WeakMotionDisplayTarget(self)
                    let link = window.displayLink(target: target, selector: #selector(WeakMotionDisplayTarget.frame(_:)))
                    displayTarget = target
                    displayLink = link
                    link.add(to: .main, forMode: .common)
                }
                return
            }
            interval = 1.0 / Double(window?.screen?.maximumFramesPerSecond ?? 60)
        } else if let deadline = chrome.nextDeadline {
            displayLink?.invalidate()
            displayLink = nil
            displayTarget = nil
            interval = max(0.001, deadline - clock.now)
        } else {
            displayLink?.invalidate()
            displayLink = nil
            displayTarget = nil
            return
        }
        let generation = timerGeneration
        let next = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.timerGeneration == generation else { return }
                self.refresh()
            }
        }
        next.tolerance = chrome.hasActiveTransitions || surfaces.hasActiveTransitions ? 0 : 0.005
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }
}

private struct MotionAdapterPresentation: Equatable {
    let values: [Double]
    let active: [TransientSurface]
    let visible: [TransientSurface]
    let preferences: MotionPreferences
    init(chrome: ChromeMotionController, surfaces: TransientSurfaceMotionController) {
        values = [chrome.sidebar.presentation, chrome.sidebar.target, chrome.context.presentation,
                  chrome.titlebar.presentation, chrome.pointer.presentation, chrome.pointer.target,
                  surfaces.palette.presentation, surfaces.settings.presentation, surfaces.conflict.presentation,
                  surfaces.overlay.presentation, surfaces.conflictBanner.presentation]
        active = surfaces.activeSurfaceStack
        visible = surfaces.visualSurfaceStack
        preferences = chrome.preferences
    }
}

@MainActor private final class WeakMotionDisplayTarget: NSObject {
    weak var adapter: WindowMotionAdapter?
    init(_ adapter: WindowMotionAdapter) { self.adapter = adapter }
    @objc func frame(_ link: CADisplayLink) {
        ClioSignpost.interval("MotionFrame") { adapter?.refresh() }
    }
}

@MainActor private final class WeakMotionResponder {
    weak var value: NSResponder?
    private let selections: [NSValue]?
    private let visibleOrigin: NSPoint?
    private let documentIdentity: UUID?
    init(_ value: NSResponder?, documentIdentity: UUID?) {
        self.value = value
        self.documentIdentity = documentIdentity
        let text = value as? NSTextView
        selections = text?.selectedRanges
        visibleOrigin = text?.enclosingScrollView?.contentView.bounds.origin
    }
    func restoreViewport(documentIdentity currentIdentity: UUID?) {
        guard let text = value as? NSTextView else { return }
        // The native editor remains mounted when tabs change. A snapshot from
        // another tab may restore its responder, but must not apply stale ranges.
        guard currentIdentity == documentIdentity else { return }
        if let selections { text.selectedRanges = selections }
        if let visibleOrigin, let scroll = text.enclosingScrollView {
            scroll.contentView.scroll(to: visibleOrigin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}
