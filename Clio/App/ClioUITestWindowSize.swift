import CoreGraphics

/// Parses the `CLIO_UI_TEST_WINDOW_SIZE` launch environment variable
/// ("WIDTHxHEIGHT", e.g. "480x400"), which UI tests use to pin the editor
/// window to a deterministic size instead of dragging or otherwise
/// simulating a resize. Never consulted outside `CLIO_UI_TESTING == "1"`
/// (see `WindowProbeView.configureWindowIfNeeded` in `ContentView.swift`).
enum ClioUITestWindowSize {
    static func parse(_ value: String?) -> CGSize? {
        guard let value else { return nil }
        let parts = value.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let width = Double(parts[0]), width > 0,
              let height = Double(parts[1]), height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
