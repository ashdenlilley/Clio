import Foundation

/// Pure state for writing chrome and the vertical sidebar. The view layer owns
/// drawing and drives `tick()` from a display link or the next exposed deadline.
final class ChromeMotionController {
    private let clock: MotionClock

    private(set) var preferences: MotionPreferences
    private(set) var sidebar: ReversibleMotionStateMachine
    private(set) var context: ReversibleMotionStateMachine
    private(set) var titlebar: ReversibleMotionStateMachine
    private(set) var pointer: ReversibleMotionStateMachine

    private(set) var isSidebarPinned: Bool
    private(set) var isSidebarTemporary = false
    private(set) var isSidebarHovered = false
    private(set) var isSidebarFocused = false
    private(set) var isSidebarDragged = false
    private(set) var isChromeFadeEnabled: Bool

    private var writingStartedAt: TimeInterval?
    private var didTriggerWritingThreshold = false
    private var didTriggerContextFade = false
    private var wasSidebarCollapsedByWriting = false

    private var temporarySidebarDeadline: TimeInterval?
    private var gestureStartPresentation: Double?
    private var gestureStartTarget: Double?
    private var gestureWasTemporary = false
    private var pointerWakeAnchor: MotionPoint
    private var events: [MotionEvent] = []

    init(
        clock: MotionClock,
        preferences: MotionPreferences = .standard,
        sidebarInitiallyVisible: Bool = true,
        sidebarPinned: Bool = false,
        chromeFadeEnabled: Bool = true,
        pointerLocation: MotionPoint = .init(x: 0, y: 0)
    ) {
        self.clock = clock
        self.preferences = preferences
        isSidebarPinned = sidebarPinned
        isChromeFadeEnabled = chromeFadeEnabled
        let sidebarPresentation = sidebarInitiallyVisible ? 1.0 : 0.0
        sidebar = ReversibleMotionStateMachine(
            initialPresentation: sidebarPresentation
        )
        context = ReversibleMotionStateMachine(initialPresentation: 1)
        titlebar = ReversibleMotionStateMachine(initialPresentation: 1)
        pointer = ReversibleMotionStateMachine(initialPresentation: 1)
        pointerWakeAnchor = pointerLocation
    }

    var isWritingBurstActive: Bool { writingStartedAt != nil }
    var isSidebarIntendedVisible: Bool { sidebar.target > 0 }
    var sidebarAllowsHitTesting: Bool { sidebar.allowsHitTesting }

    var hasActiveTransitions: Bool {
        sidebar.hasActiveTransition
            || context.hasActiveTransition
            || titlebar.hasActiveTransition
            || pointer.hasActiveTransition
    }

    /// The next semantic timer boundary. Active animation frames are driven by
    /// the view adapter and are intentionally not represented as timers here.
    var nextDeadline: TimeInterval? {
        var deadlines: [TimeInterval] = []
        if let writingStartedAt {
            if !didTriggerWritingThreshold {
                deadlines.append(writingStartedAt + MotionContract.writingThreshold)
            } else if !didTriggerContextFade {
                deadlines.append(
                    writingStartedAt
                        + MotionContract.writingThreshold
                        + MotionContract.contextFadeDelay
                )
            }
        }
        if isSidebarTemporary,
           !hasTemporaryDismissalBlocker,
           let temporarySidebarDeadline {
            deadlines.append(temporarySidebarDeadline)
        }
        return deadlines.min()
    }

    /// Starts one writing epoch. Repeated key events do not move the deadline:
    /// chrome begins hiding five seconds after writing starts, as approved.
    func noteTyping() {
        tick()
        guard isChromeFadeEnabled else { return }
        guard writingStartedAt == nil else { return }
        writingStartedAt = clock.now
        didTriggerWritingThreshold = false
        didTriggerContextFade = false
    }

    /// Ends continuity before the threshold. It does not wake already-hidden
    /// chrome; only an intentional restoration input (such as pointer movement)
    /// does that.
    func endWritingBurst() {
        tick()
        writingStartedAt = nil
        didTriggerWritingThreshold = false
        didTriggerContextFade = false
    }

    /// Enables or disables the writing-triggered chrome treatment. Disabling
    /// it cancels semantic deadlines and restores only chrome that this feature
    /// hid; a sidebar the writer hid explicitly remains hidden.
    func setChromeFadeEnabled(_ enabled: Bool) {
        tick()
        guard isChromeFadeEnabled != enabled else { return }
        isChromeFadeEnabled = enabled

        guard !enabled else { return }
        writingStartedAt = nil
        didTriggerWritingThreshold = false
        didTriggerContextFade = false

        let time = clock.now
        retargetContext(to: 1, at: time, recipe: MotionContract.chromeRestore)
        retargetTitlebar(to: 1, at: time, recipe: MotionContract.chromeRestore)
        retargetPointer(to: 1, at: time, recipe: MotionContract.chromeRestore)

        if wasSidebarCollapsedByWriting {
            retargetSidebar(to: 1, at: time, recipe: MotionContract.sidebarReveal)
            wasSidebarCollapsedByWriting = false
        }
    }

    func seedPointerLocation(_ location: MotionPoint) {
        pointerWakeAnchor = location
    }

    /// Accumulates jitter relative to the point at which chrome was last awake.
    /// Exactly four pixels is an intentional movement; anything below is ignored.
    func pointerMoved(to location: MotionPoint) {
        tick()

        let chromeIsRestingVisible = context.target == 1
            && titlebar.target == 1
            && pointer.target == 1
            && !context.hasActiveTransition
            && !titlebar.hasActiveTransition
            && !pointer.hasActiveTransition

        if chromeIsRestingVisible {
            pointerWakeAnchor = location
            return
        }

        guard pointerWakeAnchor.distance(to: location)
            >= MotionContract.pointerJitterThreshold else { return }

        let time = clock.now
        retargetContext(to: 1, at: time, recipe: MotionContract.chromeRestore)
        retargetTitlebar(to: 1, at: time, recipe: MotionContract.chromeRestore)
        retargetPointer(to: 1, at: time, recipe: MotionContract.chromeRestore)
        // Waking the controls starts a fresh writing epoch on the next key input.
        writingStartedAt = nil
        didTriggerWritingThreshold = false
        didTriggerContextFade = false
        pointerWakeAnchor = location
    }

    func toggleSidebar() {
        tick()
        abandonSidebarGesture()
        wasSidebarCollapsedByWriting = false
        let time = clock.now
        if isSidebarIntendedVisible {
            retargetSidebar(to: 0, at: time, recipe: MotionContract.sidebarHide)
        } else {
            retargetSidebar(to: 1, at: time, recipe: MotionContract.sidebarReveal)
        }
        isSidebarTemporary = false
        temporarySidebarDeadline = nil
    }

    func setSidebarPinned(_ pinned: Bool) {
        tick()
        abandonSidebarGesture()
        wasSidebarCollapsedByWriting = false
        isSidebarPinned = pinned
        isSidebarTemporary = false
        temporarySidebarDeadline = nil
        if pinned {
            retargetSidebar(
                to: 1,
                at: clock.now,
                recipe: MotionContract.sidebarReveal
            )
        }
    }

    func revealSidebarTemporarily() {
        tick()
        abandonSidebarGesture()
        wasSidebarCollapsedByWriting = false
        let time = clock.now
        retargetSidebar(to: 1, at: time, recipe: MotionContract.sidebarReveal)
        guard !isSidebarPinned else { return }
        isSidebarTemporary = true
        temporarySidebarDeadline = time + MotionContract.temporarySidebarDelay
    }

    func hideSidebar() {
        tick()
        abandonSidebarGesture()
        wasSidebarCollapsedByWriting = false
        retargetSidebar(
            to: 0,
            at: clock.now,
            recipe: MotionContract.sidebarHide
        )
        isSidebarTemporary = false
        temporarySidebarDeadline = nil
    }

    func recordSidebarInteraction() {
        tick()
        guard isSidebarTemporary, !isSidebarPinned else { return }
        temporarySidebarDeadline = clock.now + MotionContract.temporarySidebarDelay
    }

    func setSidebarHovered(_ hovered: Bool) {
        tick()
        guard isSidebarHovered != hovered else { return }
        isSidebarHovered = hovered
        recordSidebarInteractionAfterStateChange()
    }

    func setSidebarFocused(_ focused: Bool) {
        tick()
        guard isSidebarFocused != focused else { return }
        isSidebarFocused = focused
        recordSidebarInteractionAfterStateChange()
    }

    /// Begins a gesture from the current presentation, including midway through
    /// a programmatic reveal or hide.
    func beginSidebarGesture() {
        tick()
        guard gestureStartPresentation == nil else { return }
        _ = sidebar.advance(to: clock.now)
        gestureStartPresentation = sidebar.presentation
        gestureStartTarget = sidebar.target
        gestureWasTemporary = isSidebarTemporary
        wasSidebarCollapsedByWriting = false
        isSidebarDragged = true
        temporarySidebarDeadline = nil
    }

    /// Positive translation reveals and negative translation hides. The update
    /// is normalized by width and applied without easing for one-to-one tracking.
    func updateSidebarGesture(translation: Double, sidebarWidth: Double) {
        guard let gestureStartPresentation, sidebarWidth > 0 else { return }
        let progress = gestureStartPresentation + (translation / sidebarWidth)
        let generation = sidebar.setInteractivePresentation(progress)
        events.append(
            MotionEvent(
                component: .sidebar,
                issuedAt: clock.now,
                kind: .interactive(
                    generation: generation,
                    presentation: sidebar.presentation
                )
            )
        )
    }

    /// Velocity is expressed in normalized sidebar-widths per second. A clear
    /// reversal settles immediately in that direction; otherwise halfway wins.
    func endSidebarGesture(normalizedVelocity: Double = 0) {
        guard gestureStartPresentation != nil else { return }
        let time = clock.now
        clearSidebarGestureState()

        let shouldReveal: Bool
        if abs(normalizedVelocity) >= 0.05 {
            shouldReveal = normalizedVelocity > 0
        } else {
            shouldReveal = sidebar.presentation >= 0.5
        }

        if shouldReveal {
            retargetSidebar(to: 1, at: time, recipe: MotionContract.sidebarReveal)
            if !isSidebarPinned {
                isSidebarTemporary = true
                temporarySidebarDeadline = time + MotionContract.temporarySidebarDelay
            }
        } else {
            retargetSidebar(to: 0, at: time, recipe: MotionContract.sidebarHide)
            isSidebarTemporary = false
            temporarySidebarDeadline = nil
        }
    }

    /// Cancels a gesture without accepting its interactive destination. The
    /// sidebar settles back toward the intent that existed when the gesture
    /// began, and a temporary reveal receives a fresh post-interaction delay.
    func cancelSidebarGesture() {
        tick()
        guard gestureStartPresentation != nil else { return }
        let target = gestureStartTarget ?? sidebar.target
        let wasTemporary = gestureWasTemporary
        let time = clock.now
        clearSidebarGestureState()

        retargetSidebar(
            to: target,
            at: time,
            recipe: target > 0
                ? MotionContract.sidebarReveal
                : MotionContract.sidebarHide
        )

        if target > 0, wasTemporary, !isSidebarPinned {
            isSidebarTemporary = true
            temporarySidebarDeadline = time + MotionContract.temporarySidebarDelay
        } else if target <= 0 {
            isSidebarTemporary = false
            temporarySidebarDeadline = nil
        }
    }

    func setMotionPreferences(_ newPreferences: MotionPreferences) {
        tick()
        guard preferences != newPreferences else { return }
        preferences = newPreferences
        let time = clock.now

        if sidebar.hasActiveTransition {
            retargetSidebar(
                to: sidebar.target,
                at: time,
                recipe: sidebar.target > 0
                    ? MotionContract.sidebarReveal
                    : MotionContract.sidebarHide
            )
        }
        if context.hasActiveTransition {
            retargetContext(
                to: context.target,
                at: time,
                recipe: context.target > 0
                    ? MotionContract.chromeRestore
                    : MotionContract.contextHide
            )
        }
        if titlebar.hasActiveTransition {
            retargetTitlebar(
                to: titlebar.target,
                at: time,
                recipe: titlebar.target > 0
                    ? MotionContract.chromeRestore
                    : MotionContract.titlebarHide
            )
        }
        if pointer.hasActiveTransition {
            retargetPointer(
                to: pointer.target,
                at: time,
                recipe: pointer.target > 0
                    ? MotionContract.chromeRestore
                    : MotionContract.contextHide
            )
        }
    }

    /// Advances semantic timers and presentation state to the clock's current
    /// instant. Scheduled transitions retain their contractual start time even
    /// if a timer coalesces and calls this method late.
    func tick() {
        let time = clock.now

        if isChromeFadeEnabled, let writingStartedAt {
            let threshold = writingStartedAt + MotionContract.writingThreshold
            if !didTriggerWritingThreshold, time >= threshold {
                didTriggerWritingThreshold = true
                if !isSidebarPinned {
                    if sidebar.target > 0 {
                        wasSidebarCollapsedByWriting = true
                    }
                    retargetSidebar(
                        to: 0,
                        at: threshold,
                        recipe: MotionContract.sidebarHide
                    )
                    isSidebarTemporary = false
                    temporarySidebarDeadline = nil
                }
                retargetTitlebar(
                    to: 0,
                    at: threshold,
                    recipe: MotionContract.titlebarHide
                )
            }

            let contextThreshold = threshold + MotionContract.contextFadeDelay
            if didTriggerWritingThreshold,
               !didTriggerContextFade,
               time >= contextThreshold {
                didTriggerContextFade = true
                retargetContext(
                    to: 0,
                    at: contextThreshold,
                    recipe: MotionContract.contextHide
                )
                retargetPointer(
                    to: 0,
                    at: contextThreshold,
                    recipe: MotionContract.contextHide
                )
            }
        }

        if isSidebarTemporary,
           !hasTemporaryDismissalBlocker,
           let temporarySidebarDeadline,
           time >= temporarySidebarDeadline {
            retargetSidebar(
                to: 0,
                at: temporarySidebarDeadline,
                recipe: MotionContract.sidebarHide
            )
            isSidebarTemporary = false
            self.temporarySidebarDeadline = nil
        }

        _ = sidebar.advance(to: time)
        _ = context.advance(to: time)
        _ = titlebar.advance(to: time)
        _ = pointer.advance(to: time)
    }

    func drainEvents() -> [MotionEvent] {
        defer { events.removeAll(keepingCapacity: true) }
        return events
    }
}

private extension ChromeMotionController {
    var hasTemporaryDismissalBlocker: Bool {
        isSidebarHovered
            || isSidebarFocused
            || isSidebarPinned
            || isSidebarDragged
    }

    /// A newer explicit sidebar command wins over any gesture still delivering
    /// trailing or momentum events. The command itself immediately establishes
    /// the next target from the current interactive presentation.
    func abandonSidebarGesture() {
        guard gestureStartPresentation != nil || isSidebarDragged else { return }
        clearSidebarGestureState()
    }

    func clearSidebarGestureState() {
        gestureStartPresentation = nil
        gestureStartTarget = nil
        gestureWasTemporary = false
        isSidebarDragged = false
    }

    func recordSidebarInteractionAfterStateChange() {
        guard isSidebarTemporary, !isSidebarPinned else { return }
        temporarySidebarDeadline = clock.now + MotionContract.temporarySidebarDelay
    }

    func retargetSidebar(
        to target: Double,
        at time: TimeInterval,
        recipe: MotionRecipe
    ) {
        if let transition = sidebar.retarget(
            to: target,
            at: time,
            recipe: recipe,
            preferences: preferences
        ) {
            events.append(
                MotionEvent(
                    component: .sidebar,
                    issuedAt: time,
                    kind: .transition(transition)
                )
            )
        }
    }

    func retargetContext(
        to target: Double,
        at time: TimeInterval,
        recipe: MotionRecipe
    ) {
        if let transition = context.retarget(
            to: target,
            at: time,
            recipe: recipe,
            preferences: preferences
        ) {
            events.append(
                MotionEvent(
                    component: .context,
                    issuedAt: time,
                    kind: .transition(transition)
                )
            )
        }
    }

    func retargetTitlebar(
        to target: Double,
        at time: TimeInterval,
        recipe: MotionRecipe
    ) {
        if let transition = titlebar.retarget(
            to: target,
            at: time,
            recipe: recipe,
            preferences: preferences
        ) {
            events.append(
                MotionEvent(
                    component: .titlebar,
                    issuedAt: time,
                    kind: .transition(transition)
                )
            )
        }
    }

    func retargetPointer(
        to target: Double,
        at time: TimeInterval,
        recipe: MotionRecipe
    ) {
        if let transition = pointer.retarget(
            to: target,
            at: time,
            recipe: recipe,
            preferences: preferences
        ) {
            events.append(
                MotionEvent(
                    component: .pointer,
                    issuedAt: time,
                    kind: .transition(transition)
                )
            )
        }
    }
}
