import AppKit
import Observation
import XCTest
@testable import Clio

private final class AdapterClock: MotionClock {
    var now: TimeInterval = 0
}

private final class MotionObservationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    func mark() { lock.lock(); changed = true; lock.unlock() }
    var wasChanged: Bool { lock.lock(); defer { lock.unlock() }; return changed }
}

@MainActor final class WindowMotionAdapterTests: XCTestCase {
    func testDisplayLinkRequestsNativeCadenceWithAdaptiveLowPowerRange() {
        let native = WindowMotionAdapter.frameRateRange(maximumFPS: 120, lowPower: false)
        XCTAssertEqual(native.minimum, 30)
        XCTAssertEqual(native.maximum, 120)
        XCTAssertEqual(native.preferred, 120)
        let lowPower = WindowMotionAdapter.frameRateRange(maximumFPS: 120, lowPower: true)
        XCTAssertEqual(lowPower.minimum, 30)
        XCTAssertEqual(lowPower.maximum, 60)
        XCTAssertEqual(lowPower.preferred, 60)
    }

    func testSidebarFramesDoNotInvalidateEditorChromeSurfacesOrRewriteNativeControls() {
        let clock = AdapterClock()
        let adapter = WindowMotionAdapter(sidebarVisible: false, clock: clock)
        defer { adapter.stop() }
        adapter.refresh()
        let sidebar = MotionObservationProbe()
        let unrelated = MotionObservationProbe()
        withObservationTracking { _ = adapter.sidebarProgress } onChange: { sidebar.mark() }
        withObservationTracking {
            _ = adapter.contextProgress
            _ = adapter.surfaceState
            _ = adapter.hasActiveSurfaces
            _ = adapter.preferences
        } onChange: { unrelated.mark() }
        var nativeUpdates = 0
        adapter.applyNativeChrome = { nativeUpdates += 1 }
        adapter.update { $0.toggleSidebar() }
        for _ in 0..<60 { clock.now += 0.005; adapter.refresh() }
        XCTAssertTrue(sidebar.wasChanged)
        XCTAssertFalse(unrelated.wasChanged)
        XCTAssertEqual(nativeUpdates, 1, "Only the changed toggle intent updates native accessibility, not each frame")
        adapter.synchronizeSurface(.palette, presented: true, viewport: .zero)
        XCTAssertTrue(unrelated.wasChanged)
        XCTAssertTrue(adapter.hasActiveSurfaces)
    }

    func testSurfaceFramesDoNotInvalidateSidebarOrContextObservers() {
        let clock = AdapterClock()
        let adapter = WindowMotionAdapter(clock: clock)
        defer { adapter.stop() }
        adapter.synchronizeSurface(.palette, presented: true, viewport: .zero)
        let unrelated = MotionObservationProbe()
        let surface = MotionObservationProbe()
        withObservationTracking {
            _ = adapter.sidebarProgress
            _ = adapter.contextProgress
            _ = adapter.hasActiveSurfaces
        } onChange: { unrelated.mark() }
        withObservationTracking { _ = adapter.surfaceState } onChange: { surface.mark() }
        for _ in 0..<40 { clock.now += 0.005; adapter.refresh() }
        XCTAssertTrue(surface.wasChanged)
        XCTAssertFalse(unrelated.wasChanged)
    }

    func testNativeDisplayLinkAdvancesVisibleWindowAndStopsAtRest() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLIO_RUN_NATIVE_MOTION_TESTS"] == "1",
                          "Native display-link gate runs separately on an unlocked desktop in the ad-hoc signed rendering host.")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let adapter = WindowMotionAdapter(sidebarVisible: false)
        adapter.window = window
        window.orderFront(nil)
        defer { adapter.stop(); window.close() }
        adapter.update { $0.toggleSidebar() }
        XCTAssertTrue(adapter.isDrivingFrames)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(adapter.sidebarProgress, 1)
        XCTAssertFalse(adapter.isDrivingFrames)
    }

    func testPhasedGestureTracksPixelsReversesCancelsAndRejectsMomentum() {
        let clock = AdapterClock()
        let adapter = WindowMotionAdapter(sidebarVisible: false, clock: clock)
        defer { adapter.stop() }
        func send(_ delta: Double, phase: NSEvent.Phase, momentum: NSEvent.Phase = []) -> Bool {
            adapter.handleSidebarScroll(deltaX: delta, deltaY: 0, precise: true, phase: phase,
                                        momentum: momentum, inverted: true, timestamp: clock.now)
        }
        XCTAssertTrue(send(84, phase: .began))
        XCTAssertEqual(adapter.sidebarProgress, 1.0 / 3, accuracy: 0.000_001)
        clock.now += 0.01
        XCTAssertTrue(send(84, phase: .changed))
        XCTAssertEqual(adapter.sidebarProgress, 2.0 / 3, accuracy: 0.000_001)
        clock.now += 0.01
        XCTAssertTrue(send(-42, phase: .changed))
        XCTAssertEqual(adapter.sidebarProgress, 0.5, accuracy: 0.000_001)
        XCTAssertFalse(send(100, phase: [], momentum: .changed))
        XCTAssertEqual(adapter.sidebarProgress, 0.5, accuracy: 0.000_001)
        XCTAssertTrue(send(0, phase: .cancelled))
        XCTAssertFalse(adapter.chrome.isSidebarIntendedVisible)
        clock.now += 1
        adapter.refresh()
        XCTAssertEqual(adapter.sidebarProgress, 0)
        XCTAssertTrue(send(160, phase: .began))
        XCTAssertTrue(send(0, phase: .ended))
        XCTAssertTrue(adapter.chrome.isSidebarTemporary)
        clock.now += 1
        adapter.refresh()
        XCTAssertEqual(adapter.sidebarProgress, 1)
        XCTAssertTrue(send(80, phase: .began))
        XCTAssertTrue(send(-10, phase: .changed))
        XCTAssertEqual(adapter.sidebarProgress, 1 - 10.0 / 252, accuracy: 0.000_001)
        XCTAssertTrue(send(0, phase: .cancelled))
    }

    func testNativeResponderSelectionAndViewportSurviveRapidPaletteReversal() {
        let clock = AdapterClock()
        let adapter = WindowMotionAdapter(clock: clock)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        window.isReleasedWhenClosed = false
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 2000))
        editor.string = String(repeating: "A line of writing\n", count: 100)
        scroll.documentView = editor
        window.contentView = scroll
        adapter.window = window
        defer { adapter.stop(); window.close() }
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 23, length: 19))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        let origin = scroll.contentView.bounds.origin
        let frame = editor.frame
        adapter.synchronizeSurface(.palette, presented: true, viewport: .zero)
        clock.now = 0.07
        adapter.refresh()
        let entering = adapter.surfaceState.palette.presentation
        adapter.synchronizeSurface(.palette, presented: false, viewport: .zero)
        XCTAssertEqual(adapter.surfaceState.palette.presentation, entering, accuracy: 0.000_001)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 23, length: 19))
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
        clock.now = 0.08
        adapter.refresh()
        let exiting = adapter.surfaceState.palette.presentation
        adapter.synchronizeSurface(.palette, presented: true, viewport: .zero)
        XCTAssertEqual(adapter.surfaceState.palette.presentation, exiting, accuracy: 0.000_001)
        adapter.synchronizeSurface(.palette, presented: false, viewport: .zero)
        clock.now = 1
        adapter.refresh()
        XCTAssertEqual(editor.frame, frame)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 23, length: 19))
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
        XCTAssertFalse(adapter.isDrivingFrames)
        XCTAssertTrue(adapter.surfaceState.visualSurfaceStack.isEmpty)
    }

    func testSidebarReversalsNeverMutateNativeEditorGeometryOrResponder() {
        let clock = AdapterClock()
        let adapter = WindowMotionAdapter(sidebarVisible: false, clock: clock)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        window.isReleasedWhenClosed = false
        window.contentView = editor
        adapter.window = window
        window.makeFirstResponder(editor)
        let frame = editor.frame
        defer { adapter.stop(); window.close() }
        for index in 0..<30 {
            adapter.update { $0.toggleSidebar() }
            let before = adapter.sidebarProgress
            clock.now += 0.003
            adapter.refresh()
            XCTAssertLessThan(abs(adapter.sidebarProgress - before), 0.25, "Frame \(index) jumped")
            XCTAssertEqual(editor.frame, frame)
            XCTAssertTrue(window.firstResponder === editor)
        }
        clock.now += 1
        adapter.refresh()
        XCTAssertFalse(adapter.isDrivingFrames)
    }

    func testIdleDeadlineAndFourPixelWakeDoNotReopenSidebar() {
        let clock = AdapterClock()
        let adapter = WindowMotionAdapter(clock: clock)
        defer { adapter.stop() }
        adapter.update { $0.noteTyping() }
        XCTAssertFalse(adapter.isDrivingFrames)
        clock.now = 4.9
        adapter.update { $0.noteTyping() }
        clock.now = 5.5
        adapter.refresh()
        XCTAssertEqual(adapter.sidebarProgress, 0)
        XCTAssertEqual(adapter.contextProgress, 0)
        adapter.update { $0.pointerMoved(to: .init(x: 3.99, y: 0)) }
        XCTAssertFalse(adapter.isDrivingFrames)
        adapter.update { $0.pointerMoved(to: .init(x: 4, y: 0)) }
        XCTAssertTrue(adapter.isDrivingFrames)
        clock.now += 0.16
        adapter.refresh()
        XCTAssertEqual(adapter.contextProgress, 1)
        XCTAssertEqual(adapter.titlebarProgress, 1)
        XCTAssertEqual(adapter.sidebarProgress, 0)
        XCTAssertFalse(adapter.isDrivingFrames)
    }

    func testContinuousPointerMovementDoesNotExtendRestorationDeadline() {
        let clock = AdapterClock()
        let adapter = WindowMotionAdapter(clock: clock)
        defer { adapter.stop() }
        adapter.update { $0.noteTyping() }
        clock.now = 6
        adapter.refresh()
        adapter.update { $0.pointerMoved(to: .init(x: 4, y: 0)) }
        for frame in 1...20 {
            clock.now = 6 + Double(frame) * 0.008
            adapter.update { $0.pointerMoved(to: .init(x: Double(frame + 1) * 4, y: 0)) }
        }
        XCTAssertEqual(adapter.contextProgress, 1)
        XCTAssertEqual(adapter.titlebarProgress, 1)
        XCTAssertEqual(adapter.sidebarProgress, 0)
        XCTAssertFalse(adapter.isDrivingFrames)
    }

    func testReduceMotionAndTransparencyPreserveDeadlinesWithShortOpacityOnlyTransitions() {
        let clock = AdapterClock()
        let adapter = WindowMotionAdapter(clock: clock)
        defer { adapter.stop() }
        adapter.setPreferences(.init(reduceMotion: true, reduceTransparency: true))
        adapter.update { $0.noteTyping() }
        clock.now = 5
        adapter.refresh()
        XCTAssertEqual(adapter.chrome.sidebar.transition?.recipe.animatedProperties, .opacity)
        XCTAssertEqual(adapter.chrome.sidebar.transition?.duration ?? 1, 0.08, accuracy: 0.000_001)
        XCTAssertEqual(adapter.contextProgress, 1)
        clock.now = 5.06
        adapter.refresh()
        XCTAssertEqual(adapter.chrome.context.transition?.recipe.animatedProperties, .opacity)
        adapter.synchronizeSurface(.settings, presented: true, viewport: .zero)
        XCTAssertEqual(adapter.surfaceState.settings.transition?.recipe.transform, MotionTransform())
        XCTAssertLessThanOrEqual(adapter.surfaceState.settings.transition?.duration ?? 1, 0.08)
        XCTAssertFalse(adapter.surfaceState.usesBackdropBlur)
        clock.now += 0.081
        adapter.refresh()
        XCTAssertEqual(adapter.surfaceState.settings.presentation, 1)
        XCTAssertFalse(adapter.isDrivingFrames)
    }

    func testFileDragPausesTemporaryDismissalAndRestartsFullIdleDelay() {
        let clock = AdapterClock()
        let adapter = WindowMotionAdapter(sidebarVisible: false, clock: clock)
        defer { adapter.stop() }
        adapter.update { $0.revealSidebarTemporarily(); $0.setSidebarFileDragged(true) }
        clock.now = 10
        adapter.refresh()
        XCTAssertEqual(adapter.sidebarProgress, 1)
        adapter.update { $0.setSidebarFileDragged(false) }
        clock.now = 13.49
        adapter.refresh()
        XCTAssertEqual(adapter.sidebarProgress, 1)
        clock.now = 14
        adapter.refresh()
        XCTAssertEqual(adapter.sidebarProgress, 0)
    }
}
