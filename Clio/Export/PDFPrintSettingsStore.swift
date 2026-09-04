import Foundation
import Observation

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
        if let data = defaults.data(forKey: key),
           let restored = try? JSONDecoder().decode(PDFPrintSettings.self, from: data),
           restored.isValid {
            settings = restored
        } else {
            settings = Self.regionalDefault()
        }
    }

    func update(_ newSettings: PDFPrintSettings) throws {
        guard newSettings.isValid else {
            throw DocumentExportError.invalidPrintSettings
        }
        settings = newSettings
    }

    func resetToRegionalDefault() {
        settings = Self.regionalDefault()
    }

    nonisolated static func regionalDefault(locale: Locale = .current) -> PDFPrintSettings {
        let usesMetric = locale.measurementSystem == .metric
        return PDFPrintSettings(
            paperName: usesMetric ? "iso-a4" : "na-letter",
            paperWidthPoints: usesMetric ? 595.2756 : 612,
            paperHeightPoints: usesMetric ? 841.8898 : 792,
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
