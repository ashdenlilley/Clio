import Foundation

/// Owns each editable buffer once, even when several windows or authorized
/// paths refer to the same physical file.
@MainActor
final class DocumentBufferRegistry: DocumentBufferRegistering {
    private final class WeakSession {
        weak var value: EditorSession?
        init(_ value: EditorSession) { self.value = value }
    }

    private var documents: [DocumentID: Document] = [:]
    private var identities: [PhysicalFileIdentity: DocumentID] = [:]
    private var locators: [DocumentLocator: DocumentID] = [:]
    private var autosavers: [DocumentID: Autosaver] = [:]
    private var sessions: [ObjectIdentifier: WeakSession] = [:]
    let identityStore: DocumentIdentityStore

    init(identityStore: DocumentIdentityStore = .shared) {
        self.identityStore = identityStore
    }

    func open(
        _ fileURL: URL,
        in workspace: Workspace,
        preferredID: DocumentID? = nil
    ) throws -> Document {
        let standardizedURL = fileURL.standardizedFileURL
        let locator = try workspace.locator(for: standardizedURL)
        let identity = PhysicalFileIdentity.authorizedFile(at: standardizedURL)

        if let existing = document(for: identity, locator: locator) {
            try identityStore.bind(
                existing.id,
                locator: locator,
                physicalIdentity: identity,
                canonicalPath: standardizedURL.resolvingSymlinksInPath().path
            )
            updateAliases(
                for: existing.id,
                identity: identity,
                locator: locator
            )
            return existing
        }

        let id = try identityStore.resolve(
            DocumentIdentityCandidate(
                locator: locator,
                physicalIdentity: identity,
                canonicalPath: standardizedURL.resolvingSymlinksInPath().path,
                preferredID: preferredID
            )
        )
        let runtimeID = canonicalRuntimeID(
            for: identity,
            locator: locator,
            preferredID: id
        )
        if runtimeID != id {
            try identityStore.bind(
                runtimeID,
                locator: locator,
                physicalIdentity: identity,
                canonicalPath: standardizedURL.resolvingSymlinksInPath().path
            )
        }
        let document = try Document(contentsOf: standardizedURL, id: runtimeID)
        documents[runtimeID] = document
        return document
    }

    /// Async hydration path for picker/search/restoration and files above the
    /// small synchronous compatibility budget. A prepared source is never
    /// registered unless its authorized path, physical identity, and content
    /// revision still match after the suspension point.
    func openInBackground(
        _ fileURL: URL,
        in workspace: Workspace,
        preferredID: DocumentID? = nil
    ) async throws -> Document {
        let standardizedURL = fileURL.standardizedFileURL
        let locator = try workspace.locator(for: standardizedURL)

        for _ in 0..<8 {
            let prepared = try await workspace.prepareDocumentInBackground(
                at: standardizedURL
            )
            guard prepared.fileURL == standardizedURL,
                  try await workspace.confirmPreparedDocument(prepared) else {
                continue
            }

            if let existing = document(for: prepared.identity, locator: locator) {
                try identityStore.bind(
                    existing.id,
                    locator: locator,
                    physicalIdentity: prepared.identity,
                    canonicalPath: prepared.canonicalPath
                )
                updateAliases(
                    for: existing.id,
                    identity: prepared.identity,
                    locator: locator,
                    canonicalPath: prepared.canonicalPath
                )
                return existing
            }

            let storedID = try identityStore.resolve(
                DocumentIdentityCandidate(
                    locator: locator,
                    physicalIdentity: prepared.identity,
                    canonicalPath: prepared.canonicalPath,
                    preferredID: preferredID
                )
            )

            let runtimeID = canonicalRuntimeID(
                for: prepared.identity,
                locator: locator,
                preferredID: storedID
            )
            if runtimeID != storedID {
                try identityStore.bind(
                    runtimeID,
                    locator: locator,
                    physicalIdentity: prepared.identity,
                    canonicalPath: prepared.canonicalPath
                )
            }
            let document = Document(
                text: prepared.source,
                fileURL: prepared.fileURL,
                preferredFilename: prepared.fileURL.lastPathComponent,
                id: runtimeID,
                expectedDiskRevision: prepared.revision,
                utf8ByteCount: prepared.utf8ByteCount
            )
            documents[runtimeID] = document
            return document
        }

        throw Workspace.WorkspaceError.externalChangeUnstable(standardizedURL)
    }

    func register(_ document: Document, in workspace: Workspace) {
        if let registered = documents[document.id], registered !== document {
            return
        }
        guard let fileURL = document.fileURL,
              let locator = try? workspace.locator(for: fileURL) else {
            documents[document.id] = document
            return
        }
        let identity = PhysicalFileIdentity.authorizedFile(at: fileURL)
        if let registered = self.document(for: identity, locator: locator),
           registered !== document {
            return
        }
        documents[document.id] = document
        updateAliases(
            for: document.id,
            identity: identity,
            locator: locator,
            canonicalPath: fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    func document(at fileURL: URL, in workspace: Workspace) -> Document? {
        let standardizedURL = fileURL.standardizedFileURL
        let identity = PhysicalFileIdentity.authorizedFile(at: standardizedURL)
        if let id = identities[identity], let document = documents[id] {
            return document
        }
        guard let locator = try? workspace.locator(for: standardizedURL),
              let id = locators[locator]
                ?? identityStore.storedDocumentID(for: locator),
              let document = documents[id] else { return nil }
        // Discovery can know an overlapping parent/nested locator before that
        // alias has ever been opened. Cache the authoritative mapping so a
        // later move event can still find the one live buffer after the source
        // path itself has disappeared.
        locators[locator] = id
        return document
    }

    func document(withID id: DocumentID) -> Document? { documents[id] }

    var openDocuments: [Document] { Array(documents.values) }

    func autosaver(for document: Document, in workspace: Workspace) -> Autosaver {
        if let autosaver = autosavers[document.id] { return autosaver }
        let autosaver = Autosaver(workspace: workspace, registry: self)
        autosavers[document.id] = autosaver
        return autosaver
    }

    func replaceAutosaver(for document: Document, in workspace: Workspace) -> Autosaver {
        autosavers[document.id]?.cancel()
        let autosaver = Autosaver(workspace: workspace, registry: self)
        autosavers[document.id] = autosaver
        boundSessions(for: document.id).forEach {
            $0.retargetDocument(to: workspace, autosaver: autosaver)
        }
        return autosaver
    }

    func bind(_ session: EditorSession, to document: Document) {
        sessions[ObjectIdentifier(session)] = WeakSession(session)
    }

    func unbind(_ session: EditorSession) {
        sessions.removeValue(forKey: ObjectIdentifier(session))
    }

    func cancelAutosave(for documentID: DocumentID) {
        autosavers[documentID]?.cancel()
    }

    func suspendAutosave(for documentID: DocumentID) {
        autosavers[documentID]?.suspendForFileOperation()
    }

    func resumeAutosave(for documentID: DocumentID) {
        autosavers[documentID]?.resumeAfterFileOperation()
    }

    func settlePendingFileIO(for documentID: DocumentID) async {
        await autosavers[documentID]?.settlePendingFileIO()
    }

    func hasActiveFileIO(for documentID: DocumentID) -> Bool {
        autosavers[documentID]?.hasActiveFileIO == true
    }

    /// Keeps the same controller object so every tab/window immediately saves
    /// through the destination workspace after a cross-workspace move.
    func retarget(_ document: Document, to workspace: Workspace) {
        let autosaver = autosaver(for: document, in: workspace)
        autosaver.retarget(to: workspace)
        boundSessions(for: document.id).forEach {
            $0.retargetDocument(to: workspace, autosaver: autosaver)
        }
    }

    /// Async file operations use this boundary before moving or snapshotting a
    /// canonical buffer. Every window bound to the document must catch up, not
    /// only the window that initiated the command.
    func settlePendingEditorEdits(for documentID: DocumentID) async throws {
        while true {
            let currentSessions = boundSessions(for: documentID)
            for session in currentSessions {
                try await session.settlePendingEditorEdits()
            }
            guard !boundSessions(for: documentID).contains(where: \.hasUnsettledEditorEdits) else {
                continue
            }
            return
        }
    }

    /// Synchronous destructive/lifecycle paths cannot await. They use this to
    /// refuse the operation and retain every visible editor buffer instead.
    func hasUnsettledEditorEdits(for documentID: DocumentID) -> Bool {
        boundSessions(for: documentID).contains(where: \.hasUnsettledEditorEdits)
    }

    /// Runs a synchronous canonical-buffer observation or mutation after every
    /// bound editor has caught up. Autosave remains suspended across the wait
    /// and operation, preventing an older debounce from acting on a path while
    /// workspace reconciliation is in flight.
    func withSettledEditorEdits<T>(
        for documentID: DocumentID,
        _ operation: @MainActor () throws -> T
    ) async throws -> T {
        suspendAutosave(for: documentID)
        defer { resumeAutosave(for: documentID) }

        repeat {
            try await settlePendingEditorEdits(for: documentID)
            await settlePendingFileIO(for: documentID)
        } while hasUnsettledEditorEdits(for: documentID)
            || hasActiveFileIO(for: documentID)

        return try operation()
    }

    /// Async counterpart used by watcher reconciliation and path mutations.
    /// Autosave remains suspended across every await; the operation itself
    /// revalidates buffer generations if typing continues while disk I/O runs.
    func withSettledDocumentIO<T>(
        for documentID: DocumentID,
        _ operation: @MainActor () async throws -> T
    ) async throws -> T {
        suspendAutosave(for: documentID)
        defer { resumeAutosave(for: documentID) }

        repeat {
            try await settlePendingEditorEdits(for: documentID)
            await settlePendingFileIO(for: documentID)
        } while hasUnsettledEditorEdits(for: documentID)
            || hasActiveFileIO(for: documentID)

        return try await operation()
    }

    func documentID(
        for identity: PhysicalFileIdentity,
        locator: DocumentLocator
    ) -> DocumentID {
        documentID(for: identity, locator: locator, preferredID: nil)
    }

    /// Adopts a discovery/index identity only when the file has not already
    /// been registered. Physical identity and locator mappings always win, so
    /// opening the same file from a tree, search result, Finder, or another
    /// window can never create a second editable buffer.
    func documentID(
        for identity: PhysicalFileIdentity,
        locator: DocumentLocator,
        preferredID: DocumentID?,
        canonicalPath: String? = nil
    ) -> DocumentID {
        let storedID = try? identityStore.resolve(
            DocumentIdentityCandidate(
                locator: locator,
                physicalIdentity: identity,
                canonicalPath: canonicalPath,
                preferredID: preferredID
            )
        )
        let id = canonicalRuntimeID(
            for: identity,
            locator: locator,
            preferredID: storedID ?? preferredID
        )
        if id != storedID {
            try? identityStore.bind(
                id,
                locator: locator,
                physicalIdentity: identity,
                canonicalPath: canonicalPath
            )
        }
        return id
    }

    private func canonicalRuntimeID(
        for identity: PhysicalFileIdentity,
        locator: DocumentLocator,
        preferredID: DocumentID?
    ) -> DocumentID {
        if let id = identities[identity] ?? locators[locator] {
            identities[identity] = id
            locators[locator] = id
            return id
        }
        let id = preferredID.flatMap { candidate in
            isAvailable(candidate, for: identity, locator: locator) ? candidate : nil
        } ?? DocumentID()
        identities[identity] = id
        locators[locator] = id
        return id
    }

    /// Reserves a stable identity for a discovered path without loading or
    /// stat-ing its contents on the main actor. `open` later adds the physical
    /// identity and coalesces aliases across overlapping workspace roots.
    func documentID(
        for locator: DocumentLocator,
        preferredID: DocumentID
    ) -> DocumentID {
        if let id = locators[locator] { return id }
        let storedID = try? identityStore.resolve(
            DocumentIdentityCandidate(locator: locator, preferredID: preferredID)
        )
        // A persisted ID may intentionally be claimed by another locator for
        // the same physical file (parent + nested workspace roots). Only an
        // unverified proposal must pass the runtime collision check.
        let id = storedID
            ?? (isUnclaimed(preferredID) ? preferredID : DocumentID())
        locators[locator] = id
        if id != storedID {
            try? identityStore.bind(id, locator: locator, physicalIdentity: nil)
        }
        return id
    }

    func updateAliases(
        for documentID: DocumentID,
        identity: PhysicalFileIdentity,
        locator: DocumentLocator
    ) {
        updateAliases(
            for: documentID,
            identity: identity,
            locator: locator,
            canonicalPath: nil
        )
    }

    private func updateAliases(
        for documentID: DocumentID,
        identity: PhysicalFileIdentity,
        locator: DocumentLocator,
        canonicalPath: String?
    ) {
        identities[identity] = documentID
        locators[locator] = documentID
        try? identityStore.bind(
            documentID,
            locator: locator,
            physicalIdentity: identity,
            canonicalPath: canonicalPath
        )
    }

    func updateAliases(for document: Document, in workspace: Workspace) {
        identities = identities.filter { $0.value != document.id }
        register(document, in: workspace)
    }

    func removeLocator(_ locator: DocumentLocator, for documentID: DocumentID) {
        if locators[locator] == documentID {
            locators.removeValue(forKey: locator)
        }
        try? identityStore.tombstone(locator, documentID: documentID)
    }

    func detach(_ documentID: DocumentID, from locator: DocumentLocator) {
        cancelAutosave(for: documentID)
        removeLocator(locator, for: documentID)
        identities = identities.filter { $0.value != documentID }
    }

    private func boundSessions(for documentID: DocumentID) -> [EditorSession] {
        sessions = sessions.filter { $0.value.value != nil }
        return sessions.values.compactMap(\.value).filter {
            $0.document?.id == documentID
        }
    }

    private func document(
        for identity: PhysicalFileIdentity,
        locator: DocumentLocator
    ) -> Document? {
        if let id = identities[identity], let document = documents[id] {
            return document
        }
        if let id = locators[locator], let document = documents[id] {
            return document
        }
        return nil
    }

    private func isAvailable(
        _ candidate: DocumentID,
        for identity: PhysicalFileIdentity,
        locator: DocumentLocator
    ) -> Bool {
        guard documents[candidate] == nil else { return false }
        guard !identities.contains(where: {
            $0.value == candidate && $0.key != identity
        }) else { return false }
        return !locators.contains(where: {
            $0.value == candidate && $0.key != locator
        })
    }

    private func isUnclaimed(_ candidate: DocumentID) -> Bool {
        documents[candidate] == nil
            && !identities.values.contains(candidate)
            && !locators.values.contains(candidate)
    }
}
