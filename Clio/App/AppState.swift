import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    enum AccentPreset: String, CaseIterable, Identifiable, Sendable {
        case green
        case amber
        case cyan

        var id: Self { self }

        var title: String {
            rawValue.capitalized
        }
    }

    private(set) var workspace: Workspace?
    private(set) var workspaceErrorMessage: String?
    private(set) var needsRecoveryAuthorization = false
    private(set) var pendingCrashRecoveryCount = 0
    private(set) var recoveredCrashBufferCount = 0
    private(set) var crashRecoveryMessage: String?
    private(set) var isCrashRecoveryDurabilityCompromised = false

    var fontSize: Double = 14 {
        didSet { defaults.set(fontSize, forKey: Keys.fontSize) }
    }

    var measure: Int = 72 {
        didSet { defaults.set(measure, forKey: Keys.measure) }
    }

    var lineHeight: Double = 1.65 {
        didSet { defaults.set(lineHeight, forKey: Keys.lineHeight) }
    }

    var typewriterAnchor: Double = 0.45 {
        didSet { defaults.set(typewriterAnchor, forKey: Keys.typewriterAnchor) }
    }

    var focusDimmingOpacity: Double = 0.28 {
        didSet { defaults.set(focusDimmingOpacity, forKey: Keys.focusDimmingOpacity) }
    }

    var isSpellCheckingEnabled = true {
        didSet { defaults.set(isSpellCheckingEnabled, forKey: Keys.spellChecking) }
    }

    var accent: AccentPreset = .green {
        didSet { defaults.set(accent.rawValue, forKey: Keys.accent) }
    }

    var isTypewriterModeEnabled = true {
        didSet { defaults.set(isTypewriterModeEnabled, forKey: Keys.typewriterMode) }
    }

    var isFocusModeEnabled = true {
        didSet { defaults.set(isFocusModeEnabled, forKey: Keys.focusMode) }
    }

    var isChromeFadeEnabled = true {
        didSet { defaults.set(isChromeFadeEnabled, forKey: Keys.chromeFade) }
    }

    var isPalettePresented = false

    @ObservationIgnored
    private let defaults: UserDefaults

    @ObservationIgnored
    private let fileManager: FileManager

    @ObservationIgnored
    private let crashRecoveryJournal: CrashRecoveryJournal

    @ObservationIgnored
    private var recoveryStore: any RecoveryPersisting

    @ObservationIgnored
    private var editorSessions: [EditorSession] = []

    @ObservationIgnored
    let documentRegistry: DocumentBufferRegistry

    @ObservationIgnored
    private(set) var conflictResolver: ConflictResolver

    @ObservationIgnored
    private(set) var documentMover: DocumentMover

    @ObservationIgnored
    private var workspaceWatcher: WorkspaceWatcher?

    @ObservationIgnored
    private var workspaceWatchTask: Task<Void, Never>?

    @ObservationIgnored
    private var crashRecoveryTask: Task<Void, Never>?

    @ObservationIgnored
    private var crashRecoveryRescanRequested = false

    @ObservationIgnored
    private var nonDurableCrashDocuments = Set<DocumentID>()

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        initialWorkspace: Workspace? = nil,
        recoveryStore: RecoveryStore? = nil,
        crashRecoveryJournal: CrashRecoveryJournal = .shared
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.crashRecoveryJournal = crashRecoveryJournal
        let activeRecoveryStore = recoveryStore
            ?? Self.restoredRecoveryStore(from: defaults)
            ?? RecoveryStore()
        self.recoveryStore = activeRecoveryStore
        documentRegistry = DocumentBufferRegistry()
        conflictResolver = ConflictResolver(recoveryStore: activeRecoveryStore)
        documentMover = DocumentMover(
            recoveryStore: activeRecoveryStore,
            fileManager: fileManager
        )

        fontSize = Self.clamp(
            Self.double(forKey: Keys.fontSize, default: 14, in: defaults),
            to: 12...20
        )
        measure = Self.clamp(
            Self.integer(forKey: Keys.measure, default: 72, in: defaults),
            to: 60...90
        )
        lineHeight = Self.clamp(
            Self.double(forKey: Keys.lineHeight, default: 1.65, in: defaults),
            to: 1.2...2.0
        )
        typewriterAnchor = Self.clamp(
            Self.double(forKey: Keys.typewriterAnchor, default: 0.45, in: defaults),
            to: 0.3...0.6
        )
        focusDimmingOpacity = Self.clamp(
            Self.double(forKey: Keys.focusDimmingOpacity, default: 0.28, in: defaults),
            to: 0.1...0.6
        )

        isSpellCheckingEnabled = Self.bool(
            forKey: Keys.spellChecking,
            default: true,
            in: defaults
        )
        isTypewriterModeEnabled = Self.bool(
            forKey: Keys.typewriterMode,
            default: true,
            in: defaults
        )
        isFocusModeEnabled = Self.bool(
            forKey: Keys.focusMode,
            default: true,
            in: defaults
        )
        isChromeFadeEnabled = Self.bool(
            forKey: Keys.chromeFade,
            default: true,
            in: defaults
        )
        if let storedAccent = defaults.string(forKey: Keys.accent),
           let accent = AccentPreset(rawValue: storedAccent) {
            self.accent = accent
        }

        if let initialWorkspace {
            workspace = initialWorkspace
            beginWatching(initialWorkspace)
        } else {
            restoreWorkspaceIfAvailable()
        }

        if recoveryStore == nil,
           workspace != nil,
           !activeRecoveryStore.isSecurityScopedAccessActive {
            needsRecoveryAuthorization = true
        }

        crashRecoveryJournal.setStatusHandler { [weak self] documentID, errorMessage in
            Task { @MainActor [weak self] in
                self?.updateCrashRecoveryStatus(
                    documentID: documentID,
                    errorMessage: errorMessage
                )
            }
        }

        Task { try? await activeRecoveryStore.pruneExpired() }
        scheduleCrashRecoveryMigration()
    }

    var isWorkspaceReady: Bool {
        workspace != nil
    }

    var workspaceRootPath: String? {
        workspace?.rootURL.path
    }

    func adjustFontSize(by amount: Double) {
        fontSize = Self.clamp(fontSize + amount, to: 12...20)
    }

    func resetFontSize() {
        fontSize = 14
    }

    func register(_ session: EditorSession) {
        guard !editorSessions.contains(where: { $0 === session }) else { return }
        editorSessions.append(session)

        guard let workspace else { return }

        if session.openingMode == .newDocument,
           !session.hasPreferredDocument {
            session.activate(
                in: workspace,
                documentURLs: [],
                registry: documentRegistry,
                conflictResolver: conflictResolver,
                documentMover: documentMover
            )
            return
        }

        do {
            let openFileURLs = Set(
                editorSessions.compactMap(\.fileURL).map(\.standardizedFileURL)
            )
            let allDocumentURLs = try workspace.documentURLs()
            let availableDocumentURLs = session.hasPreferredDocument
                ? allDocumentURLs
                : allDocumentURLs.filter {
                    !openFileURLs.contains($0.standardizedFileURL)
                }
            session.activate(
                in: workspace,
                documentURLs: availableDocumentURLs,
                registry: documentRegistry,
                conflictResolver: conflictResolver,
                documentMover: documentMover
            )
        } catch {
            // A transient enumeration failure should not strand the window or
            // discard the valid workspace grant. Keep the blank buffer usable.
            session.activate(
                in: workspace,
                documentURLs: [],
                registry: documentRegistry,
                conflictResolver: conflictResolver,
                documentMover: documentMover
            )
            presentError(
                "Clio still has access to the workspace, but couldn’t read its documents.",
                underlying: error
            )
        }
    }

    func unregister(_ session: EditorSession) {
        guard let index = editorSessions.firstIndex(where: { $0 === session }) else {
            return
        }

        guard session.flushForLifecycleEvent() else {
            // Keep the session alive if SwiftUI tears down a scene without
            // asking the window delegate. Its in-memory buffer must survive.
            return
        }

        editorSessions.remove(at: index)
        session.deactivate()
    }

    @discardableResult
    func flushAllEditorSessions() -> Bool {
        var allSaved = true

        for session in editorSessions where !session.flushForLifecycleEvent() {
            allSaved = false
        }

        return allSaved
    }

    func chooseDefaultWorkspace() {
        let panel = configuredFolderPanel(
            title: "Use Documents/Clio",
            message: "Select your Documents folder. Clio will create or reuse a Clio folder inside it.",
            prompt: "Use Documents"
        )

        if let physicalHomeURL = FileManager.default.homeDirectory(forUser: NSUserName()) {
            panel.directoryURL = physicalHomeURL.appendingPathComponent(
                "Documents",
                isDirectory: true
            )
        }

        guard panel.runModal() == .OK, let parentURL = panel.url else { return }

        do {
            // The panel grants the parent so Clio can create the child. The
            // helper ends that broad access before the exact child bookmark is
            // resolved and retained by Workspace.
            let bookmarks = try makeDefaultWorkspaceBookmarks(in: parentURL)
            try activateRecovery(from: bookmarks.recovery)
            try activateWorkspace(from: bookmarks.workspace)
        } catch {
            presentError(
                "Clio couldn’t use Documents/Clio. Select your Documents folder and try again.",
                underlying: error
            )
        }
    }

    func chooseAnotherWorkspace() {
        let panel = configuredFolderPanel(
            title: "Choose a Clio Workspace",
            message: "Choose the folder whose Markdown and text files Clio should open and save.",
            prompt: "Choose Folder"
        )

        if let currentRoot = workspace?.rootURL {
            panel.directoryURL = currentRoot
        } else if let physicalHomeURL = FileManager.default.homeDirectory(forUser: NSUserName()) {
            panel.directoryURL = physicalHomeURL
        }

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        do {
            let bookmark = try makeSelectedWorkspaceBookmark(for: selectedURL)
            try activateWorkspace(from: bookmark)
            if defaults.data(forKey: Keys.recoveryBookmark) == nil {
                chooseRecoveryFolder()
            }
        } catch {
            presentError(
                "Clio couldn’t open that workspace. Choose a readable, writable folder and try again.",
                underlying: error
            )
        }
    }

    func dismissWorkspaceError() {
        workspaceErrorMessage = nil
    }

    func dismissTransientMessage() {
        workspaceErrorMessage = nil
        if pendingCrashRecoveryCount == 0,
           !isCrashRecoveryDurabilityCompromised {
            crashRecoveryMessage = nil
        }
    }

    func chooseRecoveryFolder() {
        let panel = configuredFolderPanel(
            title: "Choose Clio Recovery Folder",
            message: "Select or create “Clio Recovery” in Documents. Clio never replaces a conflicted version until its recovery copy is written here.",
            prompt: "Use Recovery Folder"
        )
        panel.directoryURL = RecoveryStore.preferredURL
        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            needsRecoveryAuthorization = true
            workspaceErrorMessage = "Authorize a recovery folder before resolving external edits or replacing files."
            return
        }
        defer { selectedURL.stopAccessingSecurityScopedResource() }
        do {
            let bookmark = try Workspace.makeSecurityScopedBookmark(for: selectedURL)
            try activateRecovery(from: bookmark)
            workspaceErrorMessage = nil
        } catch {
            needsRecoveryAuthorization = true
            presentError(
                "Clio couldn’t retain access to that recovery folder. Choose it again.",
                underlying: error
            )
        }
    }
}

private extension AppState {
    enum WorkspaceActivationError: LocalizedError {
        case authorization(Error)
        case contents(Error)

        var requiresNewAuthorization: Bool {
            if case .authorization = self {
                return true
            }
            return false
        }

        var errorDescription: String? {
            switch self {
            case .authorization(let error), .contents(let error):
                return error.localizedDescription
            }
        }
    }

    enum Keys {
        static let fontSize = "editor.fontSize"
        static let measure = "editor.measure"
        static let lineHeight = "editor.lineHeight"
        static let typewriterAnchor = "editor.typewriterAnchor"
        static let focusDimmingOpacity = "editor.focusDimmingOpacity"
        static let spellChecking = "editor.spellChecking"
        static let accent = "appearance.accent"
        static let typewriterMode = "mode.typewriter"
        static let focusMode = "mode.focus"
        static let chromeFade = "mode.chromeFade"
        static let workspaceBookmark = "workspace.securityScopedBookmark"
        static let recoveryBookmark = "recovery.securityScopedBookmark"
    }

    func scheduleCrashRecoveryMigration() {
        guard crashRecoveryTask == nil else {
            crashRecoveryRescanRequested = true
            return
        }
        crashRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.crashRecoveryRescanRequested = false
                await self.recoverPendingCrashBuffers()
            } while self.crashRecoveryRescanRequested
            self.crashRecoveryTask = nil
        }
    }

    func updateCrashRecoveryStatus(
        documentID: DocumentID,
        errorMessage: String?
    ) {
        if let errorMessage {
            nonDurableCrashDocuments.insert(documentID)
            isCrashRecoveryDurabilityCompromised = true
            crashRecoveryMessage = "Clio could not durably protect the latest edit (\(errorMessage)). Keep the document open and choose a writable location."
            return
        }
        guard nonDurableCrashDocuments.remove(documentID) != nil else { return }
        isCrashRecoveryDurabilityCompromised = !nonDurableCrashDocuments.isEmpty
        if !isCrashRecoveryDurabilityCompromised {
            crashRecoveryMessage = "Durable crash recovery is active again."
        }
    }

    func recoverPendingCrashBuffers() async {
        let journal = crashRecoveryJournal
        let records: [CrashRecoveryRecord]
        do {
            records = try await Task.detached(priority: .utility) {
                try journal.validRecords()
            }.value
        } catch {
            crashRecoveryMessage = "Clio could not inspect its crash-recovery journal. No journal files were removed."
            return
        }

        var pending = 0
        var recovered = 0
        for record in records {
            let targetIsAuthorized = record.targetURL.map {
                workspace?.contains($0) == true
            } ?? false
            let alreadyCanonical = await Task.detached(priority: .utility) {
                guard targetIsAuthorized,
                      let targetURL = record.targetURL,
                      let values = try? targetURL.resourceValues(forKeys: [
                          .isRegularFileKey,
                          .isSymbolicLinkKey,
                      ]),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      let snapshot = try? DocumentRevisionReader.snapshot(at: targetURL) else {
                    return false
                }
                return snapshot.revision.byteCount == Int64(record.data.count)
                    && snapshot.revision.contentDigest == record.contentDigest
            }.value
            if alreadyCanonical {
                journal.remove(recordID: record.id)
                continue
            }

            do {
                _ = try await recoveryStore.preserve(
                    documentID: record.documentID,
                    filename: record.filename,
                    data: record.data,
                    sourceModificationDate: record.createdAt
                )
                journal.remove(recordID: record.id)
                recovered += 1
            } catch {
                pending += 1
            }
        }

        pendingCrashRecoveryCount = pending
        recoveredCrashBufferCount += recovered
        if pending > 0 {
            crashRecoveryMessage = "Clio found \(pending) unsaved crash-recovery \(pending == 1 ? "buffer" : "buffers"). Authorize a writable recovery folder; the app-owned journal remains intact."
        } else if recovered > 0 {
            crashRecoveryMessage = "Clio recovered \(recovered) unsaved \(recovered == 1 ? "buffer" : "buffers") into Clio Recovery."
        } else {
            crashRecoveryMessage = nil
        }
    }

    func restoreWorkspaceIfAvailable() {
        guard let bookmark = defaults.data(forKey: Keys.workspaceBookmark) else {
            return
        }

        do {
            try activateWorkspace(from: bookmark, flushingCurrentDocuments: false)
        } catch {
            let needsNewAuthorization = (error as? WorkspaceActivationError)?
                .requiresNewAuthorization ?? false

            if needsNewAuthorization {
                defaults.removeObject(forKey: Keys.workspaceBookmark)
            }

            presentError(
                needsNewAuthorization
                    ? "Clio couldn’t reopen its workspace. Choose the folder again to restore access."
                    : "Clio still has the workspace grant, but couldn’t read the folder. Try again or choose another folder.",
                underlying: error
            )
        }
    }

    static func restoredRecoveryStore(from defaults: UserDefaults) -> RecoveryStore? {
        guard let bookmark = defaults.data(forKey: Keys.recoveryBookmark),
              let restored = try? RecoveryAuthorization.restore(bookmark: bookmark) else {
            return nil
        }
        defaults.set(restored.bookmarkToPersist, forKey: Keys.recoveryBookmark)
        return restored.store
    }

    func activateRecovery(from bookmark: Data) throws {
        let restored = try RecoveryAuthorization.restore(bookmark: bookmark)
        recoveryStore = restored.store
        conflictResolver = ConflictResolver(recoveryStore: restored.store)
        documentMover = DocumentMover(
            recoveryStore: restored.store,
            fileManager: fileManager
        )
        for session in editorSessions {
            session.rebindServices(
                conflictResolver: conflictResolver,
                documentMover: documentMover
            )
        }
        defaults.set(restored.bookmarkToPersist, forKey: Keys.recoveryBookmark)
        needsRecoveryAuthorization = false
        scheduleCrashRecoveryMigration()
    }

    func activateWorkspace(
        from bookmark: Data,
        flushingCurrentDocuments: Bool = true
    ) throws {
        if flushingCurrentDocuments {
            try flushEditorSessionsBeforeWorkspaceChange()
        }

        let resolution: Workspace.BookmarkResolution
        let newWorkspace: Workspace

        do {
            resolution = try Workspace.resolveSecurityScopedBookmark(bookmark)
            newWorkspace = try Workspace(
                rootURL: resolution.url,
                crashRecoveryJournal: crashRecoveryJournal
            )
        } catch {
            throw WorkspaceActivationError.authorization(error)
        }

        let documentURLs: [URL]
        do {
            documentURLs = try newWorkspace.documentURLs()
        } catch {
            throw WorkspaceActivationError.contents(error)
        }

        let bookmarkToStore: Data
        do {
            bookmarkToStore = resolution.isStale
                ? try Workspace.makeSecurityScopedBookmark(for: resolution.url)
                : bookmark
        } catch {
            throw WorkspaceActivationError.authorization(error)
        }

        workspace = newWorkspace
        beginWatching(newWorkspace)
        var availableDocumentURLs = documentURLs
        for session in editorSessions {
            let candidates = session.hasPreferredDocument
                ? documentURLs
                : availableDocumentURLs
            session.activate(
                in: newWorkspace,
                documentURLs: candidates,
                registry: documentRegistry,
                conflictResolver: conflictResolver,
                documentMover: documentMover
            )

            if let openedURL = session.fileURL?.standardizedFileURL {
                availableDocumentURLs.removeAll {
                    $0.standardizedFileURL == openedURL
                }
            }
        }

        workspaceErrorMessage = nil
        defaults.set(bookmarkToStore, forKey: Keys.workspaceBookmark)
        scheduleCrashRecoveryMigration()
    }

    func flushEditorSessionsBeforeWorkspaceChange() throws {
        for session in editorSessions {
            try session.flush()
        }
    }

    func beginWatching(_ workspace: Workspace) {
        workspaceWatchTask?.cancel()
        let watcher = WorkspaceWatcher(
            workspaceID: workspace.id,
            rootURL: workspace.rootURL
        )
        workspaceWatcher = watcher
        workspaceWatchTask = Task { @MainActor [weak self, weak workspace] in
            let events = await watcher.events()
            for await event in events {
                guard !Task.isCancelled,
                      let self,
                      let workspace,
                      self.workspace === workspace else { break }
                await self.handleWorkspaceEvent(event, in: workspace)
            }
        }
    }

    func handleWorkspaceEvent(
        _ event: WorkspaceEvent,
        in workspace: Workspace
    ) async {
        do {
            switch event.kind {
            case .modified:
                guard let url = event.fileURL,
                      let document = documentRegistry.document(at: url, in: workspace) else {
                    return
                }
                try workspace.reconcileExternalChange(for: document)
                if document.conflict != nil {
                    documentRegistry.cancelAutosave(for: document.id)
                } else if document.fileURL != nil {
                    documentRegistry.updateAliases(for: document, in: workspace)
                }

            case .moved:
                guard let oldURL = event.previousFileURL,
                      let newURL = event.fileURL,
                      let document = documentRegistry.document(at: oldURL, in: workspace) else {
                    return
                }
                let oldLocator = try workspace.locator(for: oldURL)
                try workspace.reconcileExternalMove(
                    for: document,
                    from: oldURL,
                    to: newURL
                )
                documentRegistry.removeLocator(oldLocator, for: document.id)
                documentRegistry.updateAliases(for: document, in: workspace)
                documentRegistry.retarget(document, to: workspace)
                if document.conflict != nil {
                    documentRegistry.cancelAutosave(for: document.id)
                }

            case .deleted:
                guard let url = event.fileURL,
                      let document = documentRegistry.document(at: url, in: workspace) else {
                    return
                }
                let locator = try workspace.locator(for: url)
                documentRegistry.cancelAutosave(for: document.id)
                if document.conflict != nil {
                    try await conflictResolver.detachAfterExternalDeletion(
                        document,
                        workspace: workspace,
                        registry: documentRegistry
                    )
                } else {
                    try workspace.checkpointCrashRecovery(
                        for: document,
                        reason: .externalDeletion
                    )
                    document.markUnbacked(previous: locator)
                    documentRegistry.detach(document.id, from: locator)
                }

            case .accessLost, .error:
                workspaceErrorMessage = "Clio lost access to the workspace. Your open buffers remain in memory."

            case .rescanRequired, .rootChanged:
                for document in documentRegistry.openDocuments {
                    guard let url = document.fileURL, workspace.contains(url) else { continue }
                    if !fileManager.fileExists(atPath: url.path) {
                        let locator = try workspace.locator(for: url)
                        documentRegistry.cancelAutosave(for: document.id)
                        if document.conflict != nil {
                            try await conflictResolver.detachAfterExternalDeletion(
                                document,
                                workspace: workspace,
                                registry: documentRegistry
                            )
                        } else {
                            try workspace.checkpointCrashRecovery(
                                for: document,
                                reason: .externalDeletion
                            )
                            document.markUnbacked(previous: locator)
                            documentRegistry.detach(document.id, from: locator)
                        }
                        continue
                    }
                    try workspace.reconcileExternalChange(for: document)
                    if document.conflict != nil {
                        documentRegistry.cancelAutosave(for: document.id)
                    } else if document.fileURL != nil {
                        documentRegistry.updateAliases(for: document, in: workspace)
                    }
                }

            case .created:
                break
            }
        } catch {
            presentError(
                "Clio detected a workspace change but couldn’t safely reconcile it.",
                underlying: error
            )
        }
    }

    func makeDefaultWorkspaceBookmarks(
        in selectedParentURL: URL
    ) throws -> (workspace: Data, recovery: Data) {
        defer {
            // App Sandbox starts access for NSOpenPanel URLs on Clio's
            // behalf. This balances that temporary Powerbox scope exactly
            // once; bookmark-resolved URLs are started explicitly elsewhere.
            selectedParentURL.stopAccessingSecurityScopedResource()
        }

        let parentURL = selectedParentURL.standardizedFileURL
        let grants = try RecoveryAuthorization.createDefaultGrants(
            in: parentURL,
            fileManager: fileManager
        )
        return (grants.workspaceBookmark, grants.recoveryBookmark)
    }

    func makeSelectedWorkspaceBookmark(for selectedURL: URL) throws -> Data {
        defer {
            // Balance the scope that NSOpenPanel starts automatically.
            selectedURL.stopAccessingSecurityScopedResource()
        }
        return try Workspace.makeSecurityScopedBookmark(
            for: selectedURL.standardizedFileURL
        )
    }

    func configuredFolderPanel(
        title: String,
        message: String,
        prompt: String
    ) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        return panel
    }

    func presentError(_ guidance: String, underlying error: Error) {
        workspaceErrorMessage = "\(guidance)\n\n\(error.localizedDescription)"
    }

    static func bool(
        forKey key: String,
        default defaultValue: Bool,
        in defaults: UserDefaults
    ) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }

    static func double(
        forKey key: String,
        default defaultValue: Double,
        in defaults: UserDefaults
    ) -> Double {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.double(forKey: key)
    }

    static func integer(
        forKey key: String,
        default defaultValue: Int,
        in defaults: UserDefaults
    ) -> Int {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.integer(forKey: key)
    }

    static func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
