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
    private struct PendingFocusRestoration {
        let snapshot: MotionFocusSnapshot
        let underlay: [TransientSurface]
    }

    private let clock: MotionClock

    private(set) var preferences: MotionPreferences
    private(set) var palette = ReversibleMotionStateMachine(initialPresentation: 0)
    private(set) var settings = ReversibleMotionStateMachine(initialPresentation: 0)
    private(set) var conflict = ReversibleMotionStateMachine(initialPresentation: 0)
    private(set) var overlay = ReversibleMotionStateMachine(initialPresentation: 0)
    private(set) var conflictBanner = ReversibleMotionStateMachine(initialPresentation: 0)

    private(set) var activeSurfaces: Set<TransientSurface> = []
    /// Back-to-front order. Focus restoration is only emitted for the topmost
    /// dismissed surface; removing an underlay rewires the next surface's
    /// snapshot so a later dismissal cannot focus a defunct control.
    private(set) var activeSurfaceStack: [TransientSurface] = []
    /// Back-to-front rendering order. Unlike `activeSurfaceStack`, an exiting
    /// surface stays here until its presentation reaches zero so it cannot jump
    /// behind an underlay midway through dismissal.
    private(set) var visualSurfaceStack: [TransientSurface] = []
    private var focusSnapshots: [TransientSurface: MotionFocusSnapshot] = [:]
    private var pendingFocusRestorations: [TransientSurface: PendingFocusRestoration] = [:]
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
            activate(
                .conflict,
                capturing: resolvedFocusForPresentation(
                    of: .conflict,
                    proposed: focus
                )
            )
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
        guard activeSurfaces.contains(.conflict) else { return nil }
        let restoration = deactivate(.conflict)
        retargetConflict(to: 0, recipe: MotionContract.sheetExit)
        retargetConflictBanner(to: 0, recipe: MotionContract.conflictBannerExit)
        retainPendingRestorationIfExiting(restoration, for: .conflict)
        updateOverlay()
        pruneSettledVisualSurfaces()
        return restoration
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
        let paletteCompletion = palette.advance(to: time)
        let settingsCompletion = settings.advance(to: time)
        let conflictCompletion = conflict.advance(to: time)
        _ = overlay.advance(to: time)
        _ = conflictBanner.advance(to: time)

        clearCompletedPendingRestoration(
            for: .palette,
            completion: paletteCompletion,
            machine: palette
        )
        clearCompletedPendingRestoration(
            for: .settings,
            completion: settingsCompletion,
            machine: settings
        )
        clearCompletedPendingRestoration(
            for: .conflict,
            completion: conflictCompletion,
            machine: conflict
        )
        pruneSettledVisualSurfaces()
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
        activate(
            surface,
            capturing: resolvedFocusForPresentation(of: surface, proposed: focus)
        )

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
        guard activeSurfaces.contains(surface) else { return nil }
        let restoration = deactivate(surface)

        switch surface {
        case .palette:
            retargetPalette(to: 0, recipe: MotionContract.paletteExit)
        case .settings:
            retargetSettings(to: 0, recipe: MotionContract.sheetExit)
        case .conflict:
            assertionFailure("Use conflictResolutionSucceeded() for conflicts")
        }
        retainPendingRestorationIfExiting(restoration, for: surface)
        updateOverlay()
        pruneSettledVisualSurfaces()
        return restoration
    }

    func activate(
        _ surface: TransientSurface,
        capturing focus: MotionFocusSnapshot
    ) {
        activeSurfaces.insert(surface)
        activeSurfaceStack.append(surface)
        visualSurfaceStack.removeAll { $0 == surface }
        visualSurfaceStack.append(surface)
        focusSnapshots[surface] = focus
        pendingFocusRestorations.removeValue(forKey: surface)
    }

    /// Removes a surface while preserving the focus chain. A non-topmost
    /// dismissal cannot restore focus yet, so its predecessor snapshot replaces
    /// the snapshot captured by the surface directly above it.
    func deactivate(_ surface: TransientSurface) -> MotionFocusSnapshot? {
        guard let index = activeSurfaceStack.firstIndex(of: surface) else {
            activeSurfaces.remove(surface)
            focusSnapshots.removeValue(forKey: surface)
            return nil
        }

        let wasTopmost = index == activeSurfaceStack.index(before: activeSurfaceStack.endIndex)
        let snapshot = focusSnapshots.removeValue(forKey: surface)
        activeSurfaceStack.remove(at: index)
        activeSurfaces.remove(surface)

        if !wasTopmost,
           index < activeSurfaceStack.count,
           let snapshot {
            let surfaceImmediatelyAbove = activeSurfaceStack[index]
            focusSnapshots[surfaceImmediatelyAbove] = snapshot
        }

        return wasTopmost ? snapshot : nil
    }

    /// If a surface is reopened while its exit is still on screen, its original
    /// predecessor remains the correct restoration destination. A changed
    /// underlay means this is a genuinely new presentation and uses the newly
    /// captured focus instead.
    func resolvedFocusForPresentation(
        of surface: TransientSurface,
        proposed focus: MotionFocusSnapshot
    ) -> MotionFocusSnapshot {
        guard let pending = pendingFocusRestorations[surface],
              pending.underlay == activeSurfaceStack,
              machine(for: surface).hasActiveTransition,
              machine(for: surface).target == 0 else {
            pendingFocusRestorations.removeValue(forKey: surface)
            return focus
        }
        return pending.snapshot
    }

    func retainPendingRestorationIfExiting(
        _ restoration: MotionFocusSnapshot?,
        for surface: TransientSurface
    ) {
        guard let restoration,
              machine(for: surface).hasActiveTransition,
              machine(for: surface).target == 0 else {
            pendingFocusRestorations.removeValue(forKey: surface)
            return
        }
        pendingFocusRestorations[surface] = PendingFocusRestoration(
            snapshot: restoration,
            underlay: activeSurfaceStack
        )
    }

    func clearCompletedPendingRestoration(
        for surface: TransientSurface,
        completion: MotionCompletion?,
        machine: ReversibleMotionStateMachine
    ) {
        guard completion != nil,
              machine.target == 0,
              !activeSurfaces.contains(surface) else { return }
        pendingFocusRestorations.removeValue(forKey: surface)
    }

    func pruneSettledVisualSurfaces() {
        visualSurfaceStack.removeAll { surface in
            let machine = machine(for: surface)
            return !activeSurfaces.contains(surface)
                && !machine.hasActiveTransition
                && machine.presentation <= 0.000_001
        }
    }

    func machine(for surface: TransientSurface) -> ReversibleMotionStateMachine {
        switch surface {
        case .palette:
            palette
        case .settings:
            settings
        case .conflict:
            conflict
        }
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
