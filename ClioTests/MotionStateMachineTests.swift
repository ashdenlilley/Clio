import Foundation
import XCTest
@testable import Clio

private final class ManualMotionClock: MotionClock {
    var now: TimeInterval

    init(now: TimeInterval = 0) {
        self.now = now
    }

    func advance(by interval: TimeInterval) {
        now += interval
    }
}

final class MotionStateMachineTests: XCTestCase {
    func testSidebarRecipesMatchApprovedTimingContract() {
        XCTAssertEqual(MotionContract.sidebarReveal.duration, 0.240)
        XCTAssertEqual(
            MotionContract.sidebarReveal.curve,
            .cubicBezier(0.16, 1, 0.3, 1)
        )
        XCTAssertEqual(MotionContract.sidebarHide.duration, 0.180)
        XCTAssertEqual(
            MotionContract.sidebarHide.curve,
            .cubicBezier(0.4, 0, 1, 1)
        )
    }

    func testTransientSurfaceRecipesMatchApprovedTimingAndTransforms() {
        XCTAssertEqual(MotionContract.paletteEnter.duration, 0.170)
        XCTAssertEqual(MotionContract.paletteEnter.transform.y, -6)
        XCTAssertEqual(MotionContract.paletteEnter.transform.scale, 0.985)
        XCTAssertEqual(MotionContract.paletteExit.duration, 0.120)

        XCTAssertEqual(MotionContract.sheetEnter.duration, 0.210)
        XCTAssertEqual(MotionContract.sheetEnter.transform.y, 8)
        XCTAssertEqual(MotionContract.sheetEnter.transform.scale, 0.99)
        XCTAssertEqual(MotionContract.sheetExit.duration, 0.150)

        XCTAssertEqual(MotionContract.overlayEnter.duration, 0.140)
        XCTAssertEqual(MotionContract.overlayExit.duration, 0.100)
        XCTAssertFalse(MotionIntegrationPolicy.animatesBackdropBlur)
        XCTAssertEqual(MotionContract.conflictBannerEnter.duration, 0.220)
        XCTAssertEqual(MotionContract.conflictBannerEnter.transform.y, -8)
    }

    func testReduceMotionRetainsOnlyShortOpacityTransition() {
        let preferences = MotionPreferences(
            reduceMotion: true,
            reduceTransparency: false
        )

        let palette = MotionContract.paletteEnter.resolved(for: preferences)

        XCTAssertEqual(palette.duration, 0.080)
        XCTAssertEqual(palette.curve, .linear)
        XCTAssertEqual(palette.animatedProperties, [.opacity])
        XCTAssertEqual(palette.transform, MotionTransform())
        XCTAssertFalse(palette.usesBackdropBlur)
    }

    func testReduceTransparencyDisablesBackdropWithoutChangingTiming() {
        let preferences = MotionPreferences(
            reduceMotion: false,
            reduceTransparency: true
        )

        let overlay = MotionContract.overlayEnter.resolved(for: preferences)

        XCTAssertEqual(overlay.duration, 0.140)
        XCTAssertFalse(overlay.usesBackdropBlur)
        XCTAssertFalse(overlay.animatedProperties.contains(.blur))
    }

    func testReversalStartsAtCurrentPresentationAndInvalidatesOldGeneration() {
        var machine = ReversibleMotionStateMachine(initialPresentation: 0)
        let opening = machine.retarget(
            to: 1,
            at: 0,
            recipe: MotionContract.sidebarReveal,
            preferences: .standard
        )!
        _ = machine.advance(to: 0.080)
        let presentationAtReversal = machine.presentation

        let closing = machine.retarget(
            to: 0,
            at: 0.080,
            recipe: MotionContract.sidebarHide,
            preferences: .standard
        )!

        XCTAssertEqual(closing.from, presentationAtReversal, accuracy: 0.000_001)
        XCTAssertNotEqual(opening.generation, closing.generation)
        XCTAssertFalse(machine.isCurrent(generation: opening.generation))
        XCTAssertTrue(machine.isCurrent(generation: closing.generation))
        XCTAssertEqual(
            closing.duration,
            MotionContract.sidebarHide.duration * presentationAtReversal,
            accuracy: 0.000_001
        )
    }

    func testInteractiveUpdatesTrackGestureExactlyAndReverseImmediately() {
        var machine = ReversibleMotionStateMachine(initialPresentation: 0)

        _ = machine.setInteractivePresentation(0.72)
        XCTAssertEqual(machine.presentation, 0.72)
        XCTAssertFalse(machine.hasActiveTransition)

        _ = machine.setInteractivePresentation(0.31)
        XCTAssertEqual(machine.presentation, 0.31)
        XCTAssertFalse(machine.hasActiveTransition)
    }

    func testHitTestingDisablesAtStartOfHide() {
        var machine = ReversibleMotionStateMachine(initialPresentation: 1)
        XCTAssertTrue(machine.allowsHitTesting)

        _ = machine.retarget(
            to: 0,
            at: 0,
            recipe: MotionContract.overlayExit,
            preferences: .standard
        )

        XCTAssertFalse(machine.allowsHitTesting)
        XCTAssertEqual(machine.presentation, 1)
    }
}

final class ChromeMotionControllerTests: XCTestCase {
    func testFiveSecondWritingSequenceIsOrderedAndAnchoredToFirstKey() {
        let clock = ManualMotionClock()
        let controller = ChromeMotionController(clock: clock)

        controller.noteTyping()
        clock.advance(by: 4)
        controller.noteTyping() // Must not restart the five-second epoch.
        clock.now = 4.999
        controller.tick()
        XCTAssertEqual(controller.sidebar.target, 1)
        XCTAssertEqual(controller.context.target, 1)
        XCTAssertEqual(controller.titlebar.target, 1)

        clock.now = 5
        controller.tick()
        XCTAssertEqual(controller.sidebar.target, 0)
        XCTAssertEqual(controller.titlebar.target, 0)
        XCTAssertEqual(controller.context.target, 1)

        let thresholdEvents = controller.drainEvents()
        XCTAssertEqual(thresholdEvents.map(\.component), [.sidebar, .titlebar])
        XCTAssertEqual(thresholdEvents.map(\.issuedAt), [5, 5])

        clock.now = 5.059
        controller.tick()
        XCTAssertEqual(controller.context.target, 1)

        clock.now = 5.060
        controller.tick()
        XCTAssertEqual(controller.context.target, 0)
        XCTAssertEqual(controller.pointer.target, 0)
        let contextEvents = controller.drainEvents()
        XCTAssertEqual(contextEvents.map(\.component), [.context, .pointer])
        XCTAssertEqual(contextEvents.map(\.issuedAt), [5.060, 5.060])
    }

    func testStoppingBeforeThresholdCancelsPendingFade() {
        let clock = ManualMotionClock()
        let controller = ChromeMotionController(clock: clock)
        controller.noteTyping()
        clock.now = 2
        controller.endWritingBurst()
        clock.now = 8

        controller.tick()

        XCTAssertEqual(controller.sidebar.target, 1)
        XCTAssertEqual(controller.context.target, 1)
        XCTAssertEqual(controller.titlebar.target, 1)
        XCTAssertNil(controller.nextDeadline)
    }

    func testPinnedSidebarSurvivesWritingCollapse() {
        let clock = ManualMotionClock()
        let controller = ChromeMotionController(
            clock: clock,
            sidebarPinned: true
        )
        controller.noteTyping()
        clock.now = 5

        controller.tick()

        XCTAssertEqual(controller.sidebar.target, 1)
        XCTAssertEqual(controller.titlebar.target, 0)
        XCTAssertFalse(controller.drainEvents().contains { $0.component == .sidebar })
    }

    func testPointerJitterDoesNotWakeButFourPixelsRestoresWithoutSidebar() {
        let clock = ManualMotionClock()
        let controller = ChromeMotionController(
            clock: clock,
            pointerLocation: MotionPoint(x: 100, y: 100)
        )
        controller.noteTyping()
        clock.now = 6
        controller.tick()
        XCTAssertEqual(controller.sidebar.target, 0)
        XCTAssertEqual(controller.context.target, 0)
        _ = controller.drainEvents()

        controller.pointerMoved(to: MotionPoint(x: 102, y: 103))
        XCTAssertEqual(controller.context.target, 0)

        controller.pointerMoved(to: MotionPoint(x: 104, y: 100))
        XCTAssertEqual(controller.context.target, 1)
        XCTAssertEqual(controller.titlebar.target, 1)
        XCTAssertEqual(controller.pointer.target, 1)
        XCTAssertEqual(controller.sidebar.target, 0, "Pointer movement never reopens sidebar")

        for event in controller.drainEvents() {
            guard case let .transition(transition) = event.kind else { continue }
            XCTAssertLessThanOrEqual(transition.duration, 0.160)
        }
    }

    func testTemporarySidebarWaitsAfterHoverEnds() {
        let clock = ManualMotionClock()
        let controller = ChromeMotionController(
            clock: clock,
            sidebarInitiallyVisible: false
        )
        controller.revealSidebarTemporarily()
        controller.setSidebarHovered(true)
        clock.now = 10
        controller.tick()
        XCTAssertEqual(controller.sidebar.target, 1)

        controller.setSidebarHovered(false)
        let renewedDeadline = clock.now + MotionContract.temporarySidebarDelay
        XCTAssertEqual(controller.nextDeadline, renewedDeadline)
        clock.now = renewedDeadline - 0.001
        controller.tick()
        XCTAssertEqual(controller.sidebar.target, 1)

        clock.now = renewedDeadline
        controller.tick()
        XCTAssertEqual(controller.sidebar.target, 0)
        XCTAssertFalse(controller.isSidebarTemporary)
    }

    func testTemporarySidebarNeverAutoDismissesWhileFocusedPinnedOrDragged() {
        let clock = ManualMotionClock()
        let controller = ChromeMotionController(
            clock: clock,
            sidebarInitiallyVisible: false
        )
        controller.revealSidebarTemporarily()
        controller.setSidebarFocused(true)
        clock.now = 4
        controller.tick()
        XCTAssertEqual(controller.sidebar.target, 1)

        controller.setSidebarFocused(false)
        controller.setSidebarPinned(true)
        clock.now = 20
        controller.tick()
        XCTAssertEqual(controller.sidebar.target, 1)
        XCTAssertFalse(controller.isSidebarTemporary)

        controller.setSidebarPinned(false)
        controller.beginSidebarGesture()
        controller.updateSidebarGesture(translation: -20, sidebarWidth: 200)
        XCTAssertEqual(controller.sidebar.presentation, 0.9, accuracy: 0.000_001)
        XCTAssertTrue(controller.isSidebarDragged)
    }

    func testGestureTracksOneToOneThenVelocityReverses() {
        let clock = ManualMotionClock()
        let controller = ChromeMotionController(
            clock: clock,
            sidebarInitiallyVisible: false
        )

        controller.beginSidebarGesture()
        controller.updateSidebarGesture(translation: 140, sidebarWidth: 200)
        XCTAssertEqual(controller.sidebar.presentation, 0.7, accuracy: 0.000_001)

        controller.updateSidebarGesture(translation: 60, sidebarWidth: 200)
        XCTAssertEqual(controller.sidebar.presentation, 0.3, accuracy: 0.000_001)
        controller.endSidebarGesture(normalizedVelocity: -0.2)

        XCTAssertEqual(controller.sidebar.target, 0)
        XCTAssertEqual(
            controller.sidebar.transition?.from ?? -1,
            0.3,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            controller.sidebar.transition?.duration ?? -1,
            0.180 * 0.3,
            accuracy: 0.000_001
        )
    }

    func testToggleDuringAnimationContinuesFromPresentation() {
        let clock = ManualMotionClock()
        let controller = ChromeMotionController(
            clock: clock,
            sidebarInitiallyVisible: false
        )
        controller.toggleSidebar()
        let openingGeneration = controller.sidebar.transition!.generation
        clock.now = 0.080
        controller.tick()
        let current = controller.sidebar.presentation

        controller.toggleSidebar()

        XCTAssertEqual(controller.sidebar.transition?.from ?? -1, current, accuracy: 0.000_001)
        XCTAssertFalse(controller.sidebar.isCurrent(generation: openingGeneration))
    }

    func testReduceMotionKeepsFiveSecondAndSixtyMillisecondDelays() {
        let clock = ManualMotionClock()
        let controller = ChromeMotionController(
            clock: clock,
            preferences: MotionPreferences(
                reduceMotion: true,
                reduceTransparency: false
            )
        )
        controller.noteTyping()
        clock.now = 5
        controller.tick()
        var events = controller.drainEvents()
        XCTAssertEqual(events.map(\.issuedAt), [5, 5])
        XCTAssertTrue(events.allSatisfy { event in
            guard case let .transition(transition) = event.kind else { return false }
            return transition.duration <= 0.080
                && transition.recipe.animatedProperties == [.opacity]
        })

        clock.now = 5.059
        controller.tick()
        XCTAssertTrue(controller.drainEvents().isEmpty)
        clock.now = 5.060
        controller.tick()
        events = controller.drainEvents()
        XCTAssertEqual(events.map(\.issuedAt), [5.060, 5.060])
        XCTAssertTrue(events.allSatisfy { event in
            guard case let .transition(transition) = event.kind else { return false }
            return transition.duration <= 0.080
        })
    }
}

final class TransientSurfaceMotionControllerTests: XCTestCase {
    private func snapshot() -> MotionFocusSnapshot {
        MotionFocusSnapshot(
            responderToken: UUID(),
            viewport: EditorViewportState(
                selection: UTF16Range(location: 14, length: 3),
                topVisibleUTF16Offset: 8,
                fractionalYOffset: 0.25
            )
        )
    }

    func testPaletteRestoresExactFocusSnapshotAndUsesContractTiming() {
        let clock = ManualMotionClock()
        let controller = TransientSurfaceMotionController(clock: clock)
        let focus = snapshot()

        controller.presentPalette(capturing: focus)
        XCTAssertEqual(controller.palette.transition?.duration, 0.170)
        XCTAssertEqual(controller.overlay.transition?.duration, 0.140)

        clock.now = 0.050
        controller.tick()
        let presentation = controller.palette.presentation
        let restored = controller.dismissPalette()

        XCTAssertEqual(restored, focus)
        XCTAssertEqual(controller.palette.transition?.from ?? -1, presentation, accuracy: 0.000_001)
        XCTAssertEqual(controller.palette.target, 0)
    }

    func testRapidOpenCloseOpenInvalidatesStaleCompletionsWithoutJump() {
        let clock = ManualMotionClock()
        let controller = TransientSurfaceMotionController(clock: clock)
        let firstFocus = snapshot()
        controller.presentPalette(capturing: firstFocus)
        let firstGeneration = controller.palette.transition!.generation
        clock.now = 0.060
        controller.tick()
        let beforeClose = controller.palette.presentation
        _ = controller.dismissPalette()
        XCTAssertEqual(controller.palette.transition?.from ?? -1, beforeClose, accuracy: 0.000_001)
        let closeGeneration = controller.palette.transition!.generation

        clock.now = 0.080
        controller.tick()
        let beforeReopen = controller.palette.presentation
        controller.presentPalette(capturing: snapshot())

        XCTAssertEqual(controller.palette.transition?.from ?? -1, beforeReopen, accuracy: 0.000_001)
        XCTAssertFalse(controller.palette.isCurrent(generation: firstGeneration))
        XCTAssertFalse(controller.palette.isCurrent(generation: closeGeneration))
    }

    func testSharedOverlayRemainsWhileAnotherSurfaceIsActive() {
        let clock = ManualMotionClock()
        let controller = TransientSurfaceMotionController(clock: clock)
        controller.presentPalette(capturing: snapshot())
        controller.presentSettings(capturing: snapshot())

        _ = controller.dismissPalette()

        XCTAssertEqual(controller.overlay.target, 1)
        _ = controller.dismissSettings()
        XCTAssertEqual(controller.overlay.target, 0)
    }

    func testConflictBannerEntersOnceAndSurvivesFailedResolution() {
        let clock = ManualMotionClock()
        let controller = TransientSurfaceMotionController(clock: clock)
        let focus = snapshot()
        controller.presentConflict(capturing: focus)
        let bannerGeneration = controller.conflictBanner.transition!.generation
        _ = controller.drainEvents()

        clock.now = 0.030
        controller.presentConflict(capturing: snapshot())
        controller.conflictResolutionFailed()

        XCTAssertTrue(controller.conflictBanner.isCurrent(generation: bannerGeneration))
        XCTAssertEqual(controller.conflictBanner.target, 1)
        XCTAssertEqual(controller.conflict.target, 1)
        XCTAssertTrue(controller.drainEvents().isEmpty)

        let restored = controller.conflictResolutionSucceeded()
        XCTAssertEqual(restored, focus)
        XCTAssertEqual(controller.conflictBanner.target, 0)
        XCTAssertEqual(controller.conflict.target, 0)
    }

    func testReduceMotionSurfacesRemoveTransformsAndCapDuration() {
        let clock = ManualMotionClock()
        let controller = TransientSurfaceMotionController(
            clock: clock,
            preferences: MotionPreferences(
                reduceMotion: true,
                reduceTransparency: true
            )
        )

        controller.presentSettings(capturing: snapshot())

        for event in controller.drainEvents() {
            guard case let .transition(transition) = event.kind else { continue }
            XCTAssertLessThanOrEqual(transition.duration, 0.080)
            XCTAssertEqual(transition.recipe.animatedProperties, [.opacity])
            XCTAssertEqual(transition.recipe.transform, MotionTransform())
            XCTAssertFalse(transition.recipe.usesBackdropBlur)
        }
        XCTAssertFalse(controller.usesBackdropBlur)
    }

    func testIntegrationPolicyProtectsEditorState() {
        XCTAssertFalse(MotionIntegrationPolicy.movesEditor)
        XCTAssertFalse(MotionIntegrationPolicy.changesFirstResponder)
        XCTAssertFalse(MotionIntegrationPolicy.mutatesSelection)
        XCTAssertFalse(MotionIntegrationPolicy.mutatesScrollPosition)
    }
}
