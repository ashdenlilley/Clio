import AppKit

/// Clio's deliberately small, fixed colour vocabulary.
///
/// The editor is AppKit-backed, so the canonical tokens are `NSColor` values.
/// SwiftUI callers can bridge them with `Color(nsColor:)`.
enum Palette {
    // Surface
    static let background = NSColor(clioHex: 0x000000)
    static let backgroundRaised = NSColor(clioHex: 0x0A0A0A)
    static let hairline = NSColor(clioHex: 0x1C1C1C)

    // Text
    static let foreground = NSColor(clioHex: 0xD4D4D4)
    static let emphasis = NSColor(clioHex: 0xF0F0F0)
    static let muted = NSColor(clioHex: 0x6E6E6E)
    static let marker = NSColor(clioHex: 0x4A4A4A)
    static let dimmed = NSColor(clioHex: 0x3A3A3A)

    // Meaning
    static let literal = NSColor.systemGreen
    static let reference = NSColor.systemBlue
    static let meta = NSColor.systemPurple

    // Interaction
    static let accent = NSColor(clioHex: 0x398AB0)
    static let selection = NSColor(clioHex: 0x1F2937)
    static let matchHighlight = NSColor(clioHex: 0x12291C)
    static let caret = accent
}

private extension NSColor {
    convenience init(clioHex value: UInt32) {
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
