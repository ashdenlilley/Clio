import AppKit
import Foundation
@testable import Clio

/// Tests must never replay dirty fixtures through the writer's real recovery
/// folder or shared application-support stores. Explicit test doubles still win.
@MainActor
func isolatedAppState(
    defaults: UserDefaults? = nil,
    fileManager: FileManager = .default,
    initialWorkspace: Workspace? = nil,
    recoveryStore: RecoveryStore? = nil,
    crashRecoveryJournal: CrashRecoveryJournal? = nil,
    workspaceCatalog: WorkspaceCatalog? = nil,
    discoverySettings: WorkspaceDiscoverySettings? = nil,
    searchIndex: (any SearchIndexing)? = nil,
    documentRegistry: DocumentBufferRegistry? = nil,
    conflictResolver: ConflictResolver? = nil,
    documentMover: DocumentMover? = nil,
    externalFileAccessController: SecurityScopedFileAccessController = .init(),
    parentFolderSelection: (@MainActor (URL) -> URL?)? = nil,
    activationWillOpen: (@MainActor (URL) async -> Void)? = nil,
    exportRecoveryCheckpointStore: (any ExportRecoveryCheckpointing)? = nil,
    exportRecoveryCatalog: (any ExportTransactionRecoveryCataloging)? = nil,
    folderPanelRunner: (@MainActor (NSOpenPanel) -> URL?)? = nil
) -> AppState {
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("ClioAppStateTests-\(UUID().uuidString)", isDirectory: true)
    let identityStore = DocumentIdentityStore(storageURL: root.appendingPathComponent("identities.json"))
    let registry = documentRegistry ?? DocumentBufferRegistry(identityStore: identityStore)
    let index: any SearchIndexing
    do {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        index = try searchIndex ?? SQLiteSearchIndex(databaseURL: root.appendingPathComponent("index.sqlite"), identityStore: registry.identityStore)
    } catch {
        preconditionFailure("Unable to create isolated test storage: \(error)")
    }
    return AppState(
        defaults: defaults ?? UserDefaults(suiteName: "ClioAppStateTests.\(UUID())")!,
        fileManager: fileManager,
        initialWorkspace: initialWorkspace,
        recoveryStore: recoveryStore ?? RecoveryStore(rootURL: root.appendingPathComponent("Recovery")),
        crashRecoveryJournal: crashRecoveryJournal ?? CrashRecoveryJournal(rootURL: root.appendingPathComponent("Journal")),
        workspaceCatalog: workspaceCatalog,
        discoverySettings: discoverySettings,
        searchIndex: index,
        documentRegistry: registry,
        conflictResolver: conflictResolver,
        documentMover: documentMover,
        externalFileAccessController: externalFileAccessController,
        parentFolderSelection: parentFolderSelection,
        activationWillOpen: activationWillOpen,
        exportRecoveryCheckpointStore: exportRecoveryCheckpointStore ?? ExportRecoveryCheckpointStore(rootURL: root.appendingPathComponent("ExportCheckpoints")),
        exportRecoveryCatalog: exportRecoveryCatalog ?? ExportRecoveryCatalog(rootURL: root.appendingPathComponent("ExportRecovery")),
        folderPanelRunner: folderPanelRunner ?? { panel in panel.runModal() == .OK ? panel.url : nil }
    )
}
