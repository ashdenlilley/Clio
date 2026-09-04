import AppKit
import Foundation
import Observation

struct PDFPrintGeometry: Sendable {
    static let headerHeight = 22.0
    static let footerHeight = 20.0
    static let minimumContentWidth = 72.0
    static let minimumContentHeight = 18.0

    let pageSize: CGSize
    let contentRect: CGRect

    static func resolve(
        _ settings: PDFPrintSettings,
        fallback: PDFPrintSettings
    ) throws -> Self {
        guard settings.isValid,
              fallback.isValid,
              let sourceWidth = settings.paperWidthPoints ?? fallback.paperWidthPoints,
              let sourceHeight = settings.paperHeightPoints ?? fallback.paperHeightPoints,
              sourceWidth.isFinite,
              sourceHeight.isFinite else {
            throw DocumentExportError.invalidPrintSettings
        }

        let portraitWidth = min(sourceWidth, sourceHeight)
        let portraitHeight = max(sourceWidth, sourceHeight)
        let width = settings.orientation == .portrait ? portraitWidth : portraitHeight
        let height = settings.orientation == .portrait ? portraitHeight : portraitWidth
        let margins = settings.margins
        let contentWidth = width - margins.leading - margins.trailing
        let contentHeight = height - margins.top - margins.bottom - headerHeight - footerHeight
        let values = [width, height, contentWidth, contentHeight]
        guard values.allSatisfy(\.isFinite),
              contentWidth >= minimumContentWidth,
              contentHeight >= minimumContentHeight else {
            throw DocumentExportError.invalidPrintSettings
        }

        return Self(
            pageSize: CGSize(width: width, height: height),
            contentRect: CGRect(
                x: margins.leading,
                y: margins.bottom + footerHeight,
                width: contentWidth,
                height: contentHeight
            )
        )
    }
}

@MainActor
@Observable
final class PDFPrintSettingsStore {
    private(set) var settings: PDFPrintSettings {
        didSet { persist() }
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    @ObservationIgnored
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "export.pdf.printSettings"
    ) {
        self.defaults = defaults
        self.key = key
        let fallback = Self.systemDefault()
        if let data = defaults.data(forKey: key),
           let restored = try? JSONDecoder().decode(PDFPrintSettings.self, from: data),
           (try? PDFPrintGeometry.resolve(restored, fallback: fallback)) != nil {
            settings = restored
        } else {
            settings = fallback
        }
    }

    func update(_ newSettings: PDFPrintSettings) throws {
        _ = try PDFPrintGeometry.resolve(newSettings, fallback: Self.systemDefault())
        settings = newSettings
    }

    func resetToRegionalDefault() {
        settings = Self.systemDefault()
    }

    static func systemDefault(
        printInfo: NSPrintInfo = .shared,
        locale: Locale = .current
    ) -> PDFPrintSettings {
        let regional = regionalDefault(locale: locale)
        let paperSize = printInfo.paperSize
        let candidate = PDFPrintSettings(
            paperName: printInfo.paperName?.rawValue,
            paperWidthPoints: Double(min(paperSize.width, paperSize.height)),
            paperHeightPoints: Double(max(paperSize.width, paperSize.height)),
            margins: PrintMargins(
                top: Double(printInfo.topMargin),
                leading: Double(printInfo.leftMargin),
                bottom: Double(printInfo.bottomMargin),
                trailing: Double(printInfo.rightMargin)
            ),
            orientation: printInfo.orientation == .landscape ? .landscape : .portrait
        )
        return (try? PDFPrintGeometry.resolve(candidate, fallback: regional)) == nil
            ? regional
            : candidate
    }

    nonisolated static func regionalDefault(locale: Locale = .current) -> PDFPrintSettings {
        let letterRegions: Set<String> = ["CA", "CL", "CO", "CR", "GT", "MX", "PA", "PH", "US", "VE"]
        let usesLetter = locale.region.map { letterRegions.contains($0.identifier) } ?? false
        return PDFPrintSettings(
            paperName: usesLetter ? "na-letter" : "iso-a4",
            paperWidthPoints: usesLetter ? 612 : 595.2756,
            paperHeightPoints: usesLetter ? 792 : 841.8898,
            margins: PrintMargins(top: 54, leading: 54, bottom: 54, trailing: 54),
            orientation: .portrait
        )
    }
}

private extension PDFPrintSettingsStore {
    func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}
