import AppKit

enum Typography {
    static let family = "Hack"
    static let fallbacks = ["SF Mono", "Menlo"]

    static let baseSize: CGFloat = 14
    static let lineHeight: CGFloat = 1.65
    static let paragraphGap: CGFloat = 0.75

    /// Resolves bundled Hack first, then the requested system fallbacks. The
    /// final system monospace fallback keeps the editor usable even if a font
    /// resource is accidentally omitted from a development build.
    static func font(
        size: CGFloat = baseSize,
        traits: NSFontTraitMask = [],
        name: String = "Hack-Regular"
    ) -> NSFont {
        let resolvedSize = max(1, size)
        if name != "Hack-Regular", let selected = NSFont(name: name, size: resolvedSize) {
            return traits.isEmpty ? selected : NSFontManager.shared.convert(selected, toHaveTrait: traits)
        }
        let wantsBold = traits.contains(.boldFontMask)
        let wantsItalic = traits.contains(.italicFontMask)

        for name in faceNames(bold: wantsBold, italic: wantsItalic) {
            if let font = NSFont(name: name, size: resolvedSize) {
                return font
            }
        }

        for familyName in [family] + fallbacks {
            guard let regular = NSFont(name: familyName, size: resolvedSize) else {
                continue
            }

            guard !traits.isEmpty else { return regular }
            let converted = NSFontManager.shared.convert(regular, toHaveTrait: traits)
            if NSFontManager.shared.traits(of: converted).isSuperset(of: traits) {
                return converted
            }
        }

        let weight: NSFont.Weight = wantsBold ? .bold : .regular
        let system = NSFont.monospacedSystemFont(ofSize: resolvedSize, weight: weight)
        guard wantsItalic else { return system }
        return NSFontManager.shared.convert(system, toHaveTrait: .italicFontMask)
    }

    static func characterAdvance(for font: NSFont) -> CGFloat {
        // Hack and both preferred fallbacks are fixed-pitch. Measuring a zero
        // avoids relying on a font-specific approximation in layout code.
        ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    static func paragraphStyle(
        fontSize: CGFloat,
        lineHeightMultiple: CGFloat = lineHeight,
        fontName: String = "Hack-Regular"
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let resolvedLineHeight = max(1, fontSize * lineHeightMultiple)
        style.minimumLineHeight = resolvedLineHeight
        style.maximumLineHeight = resolvedLineHeight
        style.lineBreakMode = .byWordWrapping
        style.hyphenationFactor = 0
        style.tabStops = []
        style.defaultTabInterval = characterAdvance(for: font(size: fontSize, name: fontName)) * 4
        return style.copy() as! NSParagraphStyle
    }

    private static func faceNames(bold: Bool, italic: Bool) -> [String] {
        switch (bold, italic) {
        case (true, true):
            return ["Hack-BoldItalic", "SFMono-BoldItalic", "Menlo-BoldItalic"]
        case (true, false):
            return ["Hack-Bold", "SFMono-Bold", "Menlo-Bold"]
        case (false, true):
            return ["Hack-Italic", "SFMono-RegularItalic", "Menlo-Italic"]
        case (false, false):
            return ["Hack-Regular", "Hack", "SFMono-Regular", "SF Mono", "Menlo-Regular", "Menlo"]
        }
    }
}
