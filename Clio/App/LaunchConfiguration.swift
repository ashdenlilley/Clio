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
            preconditionFailure("Unable to prepare isolated test storage: \(error)")
        }
    }
}

private extension ClioLaunchConfiguration {
    static func uiTestConfiguration(
        environment: [String: String]
    ) throws -> Self {
        let identifier = environment["CLIO_UI_TEST_ID"] ?? UUID().uuidString
        let defaultsName = "olympus.clio.mac.ui-tests.\(identifier)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioUITests-\(identifier)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let seedURL = rootURL.appendingPathComponent("seed.md")
        let seedText = "Alpha beta gamma\nSecond line\n"
        try seedText.write(to: seedURL, atomically: true, encoding: .utf8)
        let journal = CrashRecoveryJournal(rootURL: rootURL.appendingPathComponent(".crash-recovery"))
        let identities = DocumentIdentityStore(storageURL: rootURL.appendingPathComponent(".identities.json"))
        let index = try SQLiteSearchIndex(databaseURL: rootURL.appendingPathComponent(".index.sqlite"), identityStore: identities)

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
            crashRecoveryJournal: journal,
            workspaceFactory: { id, url, journal in
                try Workspace(
                    id: id,
                    rootURL: url,
                    accessSecurityScopedResource: false,
                    crashRecoveryJournal: journal
                )
            }
        )
        let descriptor = try catalog.addAuthorizedFolder(rootURL)
        let appState = AppState(
            defaults: defaults,
            recoveryStore: RecoveryStore(rootURL: rootURL.appendingPathComponent(".document-recovery")),
            crashRecoveryJournal: journal,
            workspaceCatalog: catalog,
            searchIndex: index,
            documentRegistry: DocumentBufferRegistry(identityStore: identities),
            exportRecoveryCheckpointStore: ExportRecoveryCheckpointStore(rootURL: rootURL.appendingPathComponent(".export-checkpoints")),
            exportRecoveryCatalog: ExportRecoveryCatalog(rootURL: rootURL.appendingPathComponent(".export-recovery"))
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
