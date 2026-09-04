import Foundation

/// A monotonic time source. UI adapters can drive the motion models from a
/// display link while tests use a manually advanced clock.
protocol MotionClock: AnyObject {
    var now: TimeInterval { get }
}

final class SystemMotionClock: MotionClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

struct MotionPoint: Equatable, Sendable {
    var x: Double
    var y: Double

    func distance(to other: Self) -> Double {
        hypot(other.x - x, other.y - y)
    }
}

enum MotionCurve: Equatable, Sendable {
    case linear
    case cubicBezier(Double, Double, Double, Double)

    static let easeOut = Self.cubicBezier(0.16, 1, 0.3, 1)
    static let easeIn = Self.cubicBezier(0.4, 0, 1, 1)

    /// Evaluates the timing function at a normalized timeline position.
    /// Cubic bezier x is inverted so callers receive the presentation value,
    /// rather than merely evaluating both coordinates at the same parameter.
    func value(at timelinePosition: Double) -> Double {
        let position = min(max(timelinePosition, 0), 1)
        guard case let .cubicBezier(x1, y1, x2, y2) = self else {
            return position
        }

        func coordinate(_ parameter: Double, _ first: Double, _ second: Double) -> Double {
            let inverse = 1 - parameter
            return (3 * inverse * inverse * parameter * first)
                + (3 * inverse * parameter * parameter * second)
                + (parameter * parameter * parameter)
        }

        func derivative(_ parameter: Double, _ first: Double, _ second: Double) -> Double {
            let inverse = 1 - parameter
            return (3 * inverse * inverse * first)
                + (6 * inverse * parameter * (second - first))
                + (3 * parameter * parameter * (1 - second))
        }

        var parameter = position
        for _ in 0..<8 {
            let difference = coordinate(parameter, x1, x2) - position
            guard abs(difference) > 0.000_001 else { break }
            let slope = derivative(parameter, x1, x2)
            guard abs(slope) > 0.000_001 else { break }
            parameter = min(max(parameter - difference / slope, 0), 1)
        }

        // Newton iteration can lose precision around flat endpoints. Finish
        // with a bounded binary search to keep the evaluator deterministic.
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<12 {
            let x = coordinate(parameter, x1, x2)
            if abs(x - position) <= 0.000_001 { break }
            if x < position {
                lower = parameter
            } else {
                upper = parameter
            }
            parameter = (lower + upper) / 2
        }

        return min(max(coordinate(parameter, y1, y2), 0), 1)
    }
}

struct MotionAnimatedProperties: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let opacity = Self(rawValue: 1 << 0)
    static let translation = Self(rawValue: 1 << 1)
    static let scale = Self(rawValue: 1 << 2)
    static let scrolling = Self(rawValue: 1 << 3)
    static let blur = Self(rawValue: 1 << 4)
}

struct MotionTransform: Equatable, Sendable {
    var x: Double = 0
    var y: Double = 0
    var scale: Double = 1
}

struct MotionPreferences: Equatable, Sendable {
    var reduceMotion: Bool
    var reduceTransparency: Bool

    static let standard = Self(reduceMotion: false, reduceTransparency: false)
}

struct MotionRecipe: Equatable, Sendable {
    let duration: TimeInterval
    let curve: MotionCurve
    let animatedProperties: MotionAnimatedProperties
    let transform: MotionTransform
    /// Blur is deliberately a discrete backdrop treatment, never an animated
    /// property. Reduce Transparency disables it entirely.
    let usesBackdropBlur: Bool

    init(
        duration: TimeInterval,
        curve: MotionCurve,
        animatedProperties: MotionAnimatedProperties = [.opacity],
        transform: MotionTransform = .init(),
        usesBackdropBlur: Bool = false
    ) {
        self.duration = duration
        self.curve = curve
        self.animatedProperties = animatedProperties
        self.transform = transform
        self.usesBackdropBlur = usesBackdropBlur
    }

    func resolved(for preferences: MotionPreferences) -> Self {
        guard preferences.reduceMotion else {
            var result = self
            if preferences.reduceTransparency {
                result = Self(
                    duration: duration,
                    curve: curve,
                    animatedProperties: animatedProperties.subtracting(.blur),
                    transform: transform,
                    usesBackdropBlur: false
                )
            }
            return result
        }

        return Self(
            duration: min(duration, MotionContract.reducedMotionMaximumDuration),
            curve: .linear,
            animatedProperties: [.opacity],
            transform: .init(),
            usesBackdropBlur: false
        )
    }
}

enum MotionContract {
    static let writingThreshold: TimeInterval = 5
    static let contextFadeDelay: TimeInterval = 0.060
    static let temporarySidebarDelay: TimeInterval = 3.5
    static let pointerJitterThreshold = 4.0
    static let reducedMotionMaximumDuration: TimeInterval = 0.080

    static let sidebarReveal = MotionRecipe(
        duration: 0.240,
        curve: .cubicBezier(0.16, 1, 0.3, 1),
        animatedProperties: [.opacity, .translation]
    )
    static let sidebarHide = MotionRecipe(
        duration: 0.180,
        curve: .cubicBezier(0.4, 0, 1, 1),
        animatedProperties: [.opacity, .translation]
    )
    static let contextHide = MotionRecipe(duration: 0.220, curve: .easeIn)
    static let chromeRestore = MotionRecipe(duration: 0.160, curve: .easeOut)
    static let titlebarHide = MotionRecipe(duration: 0.300, curve: .easeIn)

    static let paletteEnter = MotionRecipe(
        duration: 0.170,
        curve: .easeOut,
        animatedProperties: [.opacity, .translation, .scale],
        transform: MotionTransform(y: -6, scale: 0.985),
        usesBackdropBlur: true
    )
    static let paletteExit = MotionRecipe(
        duration: 0.120,
        curve: .easeIn,
        animatedProperties: [.opacity, .translation, .scale],
        transform: MotionTransform(y: -6, scale: 0.985),
        usesBackdropBlur: true
    )
    static let sheetEnter = MotionRecipe(
        duration: 0.210,
        curve: .easeOut,
        animatedProperties: [.opacity, .translation, .scale],
        transform: MotionTransform(y: 8, scale: 0.99),
        usesBackdropBlur: true
    )
    static let sheetExit = MotionRecipe(
        duration: 0.150,
        curve: .easeIn,
        animatedProperties: [.opacity, .translation, .scale],
        transform: MotionTransform(y: 8, scale: 0.99),
        usesBackdropBlur: true
    )
    static let overlayEnter = MotionRecipe(
        duration: 0.140,
        curve: .easeOut,
        animatedProperties: [.opacity],
        usesBackdropBlur: true
    )
    static let overlayExit = MotionRecipe(
        duration: 0.100,
        curve: .easeIn,
        animatedProperties: [.opacity],
        usesBackdropBlur: true
    )
    static let conflictBannerEnter = MotionRecipe(
        duration: 0.220,
        curve: .easeOut,
        animatedProperties: [.opacity, .translation],
        transform: MotionTransform(y: -8)
    )
    static let conflictBannerExit = MotionRecipe(
        duration: 0.150,
        curve: .easeIn,
        animatedProperties: [.opacity, .translation],
        transform: MotionTransform(y: -8)
    )
}

struct MotionTransition: Equatable, Sendable {
    let generation: UInt64
    let from: Double
    let to: Double
    let startedAt: TimeInterval
    /// Actual duration is proportional to the remaining presentation distance.
    let duration: TimeInterval
    let recipe: MotionRecipe

    var completesAt: TimeInterval { startedAt + duration }
}

struct MotionCompletion: Equatable, Sendable {
    let generation: UInt64
    let presentation: Double
}

/// A scalar, reversible presentation model. Every retarget samples the current
/// presentation, invalidates the old generation, and begins at that exact value.
/// UI completion callbacks must compare generations before applying work.
struct ReversibleMotionStateMachine: Equatable, Sendable {
    private(set) var presentation: Double
    private(set) var target: Double
    private(set) var transition: MotionTransition?
    private(set) var generation: UInt64 = 0

    init(initialPresentation: Double) {
        let value = Self.clamp(initialPresentation)
        presentation = value
        target = value
    }

    var hasActiveTransition: Bool { transition != nil }

    /// Disable hit testing as soon as a component is asked to hide. This keeps
    /// stale, invisible controls from intercepting editor input.
    var allowsHitTesting: Bool { target > 0 }

    @discardableResult
    mutating func retarget(
        to newTarget: Double,
        at time: TimeInterval,
        recipe sourceRecipe: MotionRecipe,
        preferences: MotionPreferences
    ) -> MotionTransition? {
        _ = advance(to: time)
        let destination = Self.clamp(newTarget)
        generation &+= 1
        target = destination

        let distance = abs(destination - presentation)
        guard distance > 0.000_001 else {
            presentation = destination
            transition = nil
            return nil
        }

        let recipe = sourceRecipe.resolved(for: preferences)
        let next = MotionTransition(
            generation: generation,
            from: presentation,
            to: destination,
            startedAt: time,
            duration: recipe.duration * distance,
            recipe: recipe
        )
        transition = next
        return next
    }

    /// Used by gesture adapters. Updating the finger position is deliberately
    /// animation-free so the sidebar tracks the gesture one-to-one.
    @discardableResult
    mutating func setInteractivePresentation(_ value: Double) -> UInt64 {
        generation &+= 1
        presentation = Self.clamp(value)
        target = presentation
        transition = nil
        return generation
    }

    @discardableResult
    mutating func advance(to time: TimeInterval) -> MotionCompletion? {
        guard let transition else { return nil }
        guard transition.duration > 0 else {
            presentation = transition.to
            self.transition = nil
            return MotionCompletion(
                generation: transition.generation,
                presentation: presentation
            )
        }

        let timelinePosition = (time - transition.startedAt) / transition.duration
        guard timelinePosition >= 1 else {
            if timelinePosition > 0 {
                let eased = transition.recipe.curve.value(at: timelinePosition)
                presentation = transition.from
                    + ((transition.to - transition.from) * eased)
            }
            return nil
        }

        presentation = transition.to
        self.transition = nil
        return MotionCompletion(
            generation: transition.generation,
            presentation: presentation
        )
    }

    func isCurrent(generation candidate: UInt64) -> Bool {
        generation == candidate
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

enum MotionComponent: String, CaseIterable, Equatable, Sendable {
    case sidebar
    case context
    case titlebar
    case pointer
    case palette
    case settingsSheet
    case conflictSheet
    case overlay
    case conflictBanner
}

enum MotionEventKind: Equatable, Sendable {
    case transition(MotionTransition)
    case interactive(generation: UInt64, presentation: Double)
}

struct MotionEvent: Equatable, Sendable {
    let component: MotionComponent
    let issuedAt: TimeInterval
    let kind: MotionEventKind
}

/// Integration invariants shared by every motion adapter. These intentionally
/// describe behavior rather than AppKit implementation details.
enum MotionIntegrationPolicy {
    static let movesEditor = false
    static let changesFirstResponder = false
    static let mutatesSelection = false
    static let mutatesScrollPosition = false
    static let animatesBackdropBlur = false
}
