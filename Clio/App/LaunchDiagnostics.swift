import Foundation
import os

/// Opt-in stage names only: never log paths, document text, or environment values.
enum ClioLaunchDiagnostics {
    private static let logger = Logger(subsystem: "olympus.clio.mac.launch", category: "UITest")

    static func mark(_ stage: String) {
        guard ProcessInfo.processInfo.environment["CLIO_UI_TESTING"] == "1",
              ProcessInfo.processInfo.environment["CLIO_UI_LAUNCH_DIAGNOSTICS"] == "1" else { return }
        logger.notice("Clio launch stage: \(stage, privacy: .public)")
    }
}
