import Foundation

/// Opaque UI identity plus the complete editor viewport needed to restore the
/// exact prior first responder, caret/selection, and scroll anchor.
struct MotionFocusSnapshot: Equatable, Sendable {
    let responderToken: UUID
    let viewport: EditorViewportState
}

enum TransientSurface: Equatable, Hashable, Sendable {
    case palette
    case settings
    case conflict
}

/// Coordinates palette, settings, conflicts, and their shared overlay without
/// owning any AppKit objects. Focus snapshots are returned to the adapter only
/// when the matching surface is intentionally dismissed.
final class TransientSurfaceMotionController {
    private let clock: MotionClock

    private(set) var preferences: MotionPreferences
    private(set) var palette = ReversibleMotionStateMachine(initialPresentation: 0)
    private(set) var settings = ReversibleMotionStateMachine(initialPresentation: 0)
    private(set) var conflict = ReversibleMotionStateMachine(initialPresentation: 0)
    private(set) var overlay = ReversibleMotionStateMachine(initialPresentation: 0)
    private(set) var conflictBanner = ReversibleMotionStateMachine(initialPresentation: 0)

    private(set) var activeSurfaces: Set<TransientSurface> = []
    private var focusSnapshots: [TransientSurface: MotionFocusSnapshot] = [:]
    private var events: [MotionEvent] = []

    init(
        clock: MotionClock,
        preferences: MotionPreferences = .standard
    ) {
        self.clock = clock
        self.preferences = preferences
    }

    var hasActiveTransitions: Bool {
        palette.hasActiveTransition
            || settings.hasActiveTransition
            || conflict.hasActiveTransition
            || overlay.hasActiveTransition
            || conflictBanner.hasActiveTransition
    }

    /// Backdrop blur is a discrete material choice. It never interpolates, and
    /// Reduce Transparency replaces it with an opaque treatment.
    var usesBackdropBlur: Bool { !preferences.reduceTransparency }

    func presentPalette(capturing focus: MotionFocusSnapshot) {
        present(.palette, capturing: focus)
    }

    @discardableResult
    func dismissPalette() -> MotionFocusSnapshot? {
        dismiss(.palette)
    }

    func presentSettings(capturing focus: MotionFocusSnapshot) {
        present(.settings, capturing: focus)
    }

    @discardableResult
    func dismissSettings() -> MotionFocusSnapshot? {
        dismiss(.settings)
    }

    /// Repeated external-change notifications during one unresolved conflict do
    /// not replay the banner entrance or replace the original focus snapshot.
    func presentConflict(capturing focus: MotionFocusSnapshot) {
        tick()
        let alreadyActive = activeSurfaces.contains(.conflict)
        if !alreadyActive {
            focusSnapshots[.conflict] = focus
            activeSurfaces.insert(.conflict)
            retargetConflict(to: 1, recipe: MotionContract.sheetEnter)
            retargetConflictBanner(to: 1, recipe: MotionContract.conflictBannerEnter)
            updateOverlay()
        }
    }

    /// A failed save or collision leaves both the banner and sheet fully active.
    func conflictResolutionFailed() {
        tick()
    }

    /// The banner is allowed to leave only after the canonical resolution has
    /// succeeded. The caller receives the exact pre-conflict focus snapshot.
    @discardableResult
    func conflictResolutionSucceeded() -> MotionFocusSnapshot? {
        tick()
        guard activeSurfaces.remove(.conflict) != nil else { return nil }
        retargetConflict(to: 0, recipe: MotionContract.sheetExit)
        retargetConflictBanner(to: 0, recipe: MotionContract.conflictBannerExit)
        updateOverlay()
        return focusSnapshots.removeValue(forKey: .conflict)
    }

    func setMotionPreferences(_ newPreferences: MotionPreferences) {
        tick()
        guard preferences != newPreferences else { return }
        preferences = newPreferences

        retargetActiveMachine(
            component: .palette,
            machine: &palette,
            enter: MotionContract.paletteEnter,
            exit: MotionContract.paletteExit
        )
        retargetActiveMachine(
            component: .settingsSheet,
            machine: &settings,
            enter: MotionContract.sheetEnter,
            exit: MotionContract.sheetExit
        )
        retargetActiveMachine(
            component: .conflictSheet,
            machine: &conflict,
            enter: MotionContract.sheetEnter,
            exit: MotionContract.sheetExit
        )
        retargetActiveMachine(
            component: .overlay,
            machine: &overlay,
            enter: MotionContract.overlayEnter,
            exit: MotionContract.overlayExit
        )
        retargetActiveMachine(
            component: .conflictBanner,
            machine: &conflictBanner,
            enter: MotionContract.conflictBannerEnter,
            exit: MotionContract.conflictBannerExit
        )
    }

    func tick() {
        let time = clock.now
        _ = palette.advance(to: time)
        _ = settings.advance(to: time)
        _ = conflict.advance(to: time)
        _ = overlay.advance(to: time)
        _ = conflictBanner.advance(to: time)
    }

    func drainEvents() -> [MotionEvent] {
        defer { events.removeAll(keepingCapacity: true) }
        return events
    }
}

private extension TransientSurfaceMotionController {
    func present(
        _ surface: TransientSurface,
        capturing focus: MotionFocusSnapshot
    ) {
        tick()
        guard !activeSurfaces.contains(surface) else { return }
        activeSurfaces.insert(surface)
        focusSnapshots[surface] = focus

        switch surface {
        case .palette:
            retargetPalette(to: 1, recipe: MotionContract.paletteEnter)
        case .settings:
            retargetSettings(to: 1, recipe: MotionContract.sheetEnter)
        case .conflict:
            // Conflict has stricter banner semantics and must use its dedicated API.
            assertionFailure("Use presentConflict(capturing:) for conflicts")
        }
        updateOverlay()
    }

    @discardableResult
    func dismiss(_ surface: TransientSurface) -> MotionFocusSnapshot? {
        tick()
        guard activeSurfaces.remove(surface) != nil else { return nil }

        switch surface {
        case .palette:
            retargetPalette(to: 0, recipe: MotionContract.paletteExit)
        case .settings:
            retargetSettings(to: 0, recipe: MotionContract.sheetExit)
        case .conflict:
            assertionFailure("Use conflictResolutionSucceeded() for conflicts")
        }
        updateOverlay()
        return focusSnapshots.removeValue(forKey: surface)
    }

    func updateOverlay() {
        if activeSurfaces.isEmpty {
            retargetOverlay(to: 0, recipe: MotionContract.overlayExit)
        } else {
            retargetOverlay(to: 1, recipe: MotionContract.overlayEnter)
        }
    }

    func retargetActiveMachine(
        component: MotionComponent,
        machine: inout ReversibleMotionStateMachine,
        enter: MotionRecipe,
        exit: MotionRecipe
    ) {
        guard machine.hasActiveTransition else { return }
        let time = clock.now
        if let transition = machine.retarget(
            to: machine.target,
            at: time,
            recipe: machine.target > 0 ? enter : exit,
            preferences: preferences
        ) {
            events.append(
                MotionEvent(
                    component: component,
                    issuedAt: time,
                    kind: .transition(transition)
                )
            )
        }
    }

    func retargetPalette(to target: Double, recipe: MotionRecipe) {
        record(
            component: .palette,
            transition: palette.retarget(
                to: target,
                at: clock.now,
                recipe: recipe,
                preferences: preferences
            )
        )
    }

    func retargetSettings(to target: Double, recipe: MotionRecipe) {
        record(
            component: .settingsSheet,
            transition: settings.retarget(
                to: target,
                at: clock.now,
                recipe: recipe,
                preferences: preferences
            )
        )
    }

    func retargetConflict(to target: Double, recipe: MotionRecipe) {
        record(
            component: .conflictSheet,
            transition: conflict.retarget(
                to: target,
                at: clock.now,
                recipe: recipe,
                preferences: preferences
            )
        )
    }

    func retargetOverlay(to target: Double, recipe: MotionRecipe) {
        record(
            component: .overlay,
            transition: overlay.retarget(
                to: target,
                at: clock.now,
                recipe: recipe,
                preferences: preferences
            )
        )
    }

    func retargetConflictBanner(to target: Double, recipe: MotionRecipe) {
        record(
            component: .conflictBanner,
            transition: conflictBanner.retarget(
                to: target,
                at: clock.now,
                recipe: recipe,
                preferences: preferences
            )
        )
    }

    func record(component: MotionComponent, transition: MotionTransition?) {
        guard let transition else { return }
        events.append(
            MotionEvent(
                component: component,
                issuedAt: transition.startedAt,
                kind: .transition(transition)
            )
        )
    }
}
