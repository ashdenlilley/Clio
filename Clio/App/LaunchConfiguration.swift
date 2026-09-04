import Foundation

@MainActor
struct ClioLaunchConfiguration {
    let appState: AppState
    let initialWindowRequest: EditorWindowRequest

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        guard environment["CLIO_UI_TESTING"] == "1" else {
            return Self(
                appState: AppState(),
                initialWindowRequest: .mostRecent()
            )
        }

        do {
            return try uiTestConfiguration(environment: environment)
        } catch {
            assertionFailure("Unable to prepare the UI-test workspace: \(error)")
            let defaults = UserDefaults(
                suiteName: "olympus.clio.mac.ui-tests.fallback"
            ) ?? .standard
            return Self(
                appState: AppState(defaults: defaults, searchIndex: nil),
                initialWindowRequest: .newDocument()
            )
        }
    }
}

private extension ClioLaunchConfiguration {
    static func uiTestConfiguration(
        environment: [String: String]
    ) throws -> Self {
        let identifier = environment["CLIO_UI_TEST_ID"] ?? UUID().uuidString
        let defaultsName = "olympus.clio.mac.ui-tests.\(identifier)"
        let defaults = UserDefaults(suiteName: defaultsName) ?? .standard
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioUITests-\(identifier)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let seedURL = rootURL.appendingPathComponent("seed.md")
        let seedText = "Alpha beta gamma\nSecond line\n"
        try seedText.write(to: seedURL, atomically: true, encoding: .utf8)

        let catalog = WorkspaceCatalog(
            defaults: defaults,
            bookmarkMaker: { Data($0.path.utf8) },
            bookmarkResolver: { data in
                Workspace.BookmarkResolution(
                    url: URL(
                        fileURLWithPath: String(decoding: data, as: UTF8.self)
                    ),
                    isStale: false
                )
            },
            workspaceFactory: {
                try Workspace(
                    rootURL: $0,
                    accessSecurityScopedResource: false
                )
            }
        )
        let descriptor = try catalog.addAuthorizedFolder(rootURL)
        let appState = AppState(
            defaults: defaults,
            workspaceCatalog: catalog,
            searchIndex: nil
        )

        switch environment["CLIO_UI_TEST_SCENARIO"] {
        case "blank":
            return Self(
                appState: appState,
                initialWindowRequest: .newDocument()
            )
        case "restoration":
            let tabID = UUID()
            var request = EditorWindowRequest.mostRecent()
            request.restoration = EditorWindowRestorationState(
                id: request.id,
                tabs: [
                    EditorTabRestorationState(
                        id: tabID,
                        documentID: DocumentID(),
                        locator: try DocumentLocator(
                            workspaceID: descriptor.id,
                            relativePath: "seed.md"
                        ),
                        preferredFilename: "seed.md",
                        viewport: EditorViewportState(
                            selection: UTF16Range(location: 5, length: 0),
                            topVisibleUTF16Offset: 0,
                            fractionalYOffset: 0
                        )
                    )
                ],
                activeTabID: tabID,
                isSidebarVisible: true,
                isSidebarPinned: false,
                isFullScreen: false
            )
            return Self(appState: appState, initialWindowRequest: request)
        default:
            return Self(
                appState: appState,
                initialWindowRequest: .mostRecent()
            )
        }
    }
}
