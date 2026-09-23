import SwiftUI

/// The only place Clio calls `glassEffect`. Surfaces pick a shape and whether
/// they are the selected/active element; everything else (variant, tint
/// strength, radii) is decided here so the chrome stays consistent and any
/// artifact can be tuned in one file.
///
/// The writing surface is never glass: glass samples what is behind it, and
/// behind the editor is only black.
enum GlassShape {
    /// `.row` is reserved for a future grouped/selected glass row treatment;
    /// currently unused because selected rows inside glass panels use accent
    /// fills instead of glass-on-glass (Ruling 1: no glass on glass).
    case panel, card, capsule, row

    var cornerRadius: CGFloat? {
        switch self {
        case .panel: 16
        case .card: 12
        case .row: 8
        case .capsule: nil
        }
    }
}

enum ClioGlass {
    /// Strong enough to read over black, weak enough not to compete with text.
    static let selectedTintOpacity: Double = 0.28

    static func glass(selected: Bool, accent: Color, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if selected { glass = glass.tint(accent.opacity(selectedTintOpacity)) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

extension EnvironmentValues {
    @Entry var clioAccent: Color = Color(nsColor: Palette.accent)
}

private struct ClioGlassModifier: ViewModifier {
    let shape: GlassShape
    let selected: Bool
    let interactive: Bool
    @Environment(\.clioAccent) private var accent

    func body(content: Content) -> some View {
        let glass = ClioGlass.glass(selected: selected, accent: accent, interactive: interactive)
        if let radius = shape.cornerRadius {
            content.glassEffect(glass, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content.glassEffect(glass, in: Capsule())
        }
    }
}

extension View {
    /// `selected`/`interactive` are reserved for grouped/selected glass and
    /// currently unused: selected rows inside glass panels use accent fills
    /// instead (Ruling 1).
    func clioGlass(_ shape: GlassShape, selected: Bool = false, interactive: Bool = false) -> some View {
        modifier(ClioGlassModifier(shape: shape, selected: selected, interactive: interactive))
    }
}

/// Groups sibling glass shapes so they blend instead of stacking when close.
/// Reserved for a future grouped glass treatment; currently unused because no
/// surface groups sibling glass shapes yet.
struct ClioGlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        GlassEffectContainer(spacing: spacing) { content }
    }
}
