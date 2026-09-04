import Foundation

struct DocumentIdentityCandidate: Sendable {
    let locator: DocumentLocator
    let physicalIdentity: PhysicalFileIdentity?
    let canonicalPath: String?
    let preferredID: DocumentID?

    init(
        locator: DocumentLocator,
        physicalIdentity: PhysicalFileIdentity? = nil,
        canonicalPath: String? = nil,
        preferredID: DocumentID? = nil
    ) {
        self.locator = locator
        self.physicalIdentity = physicalIdentity
        self.canonicalPath = canonicalPath
        self.preferredID = preferredID
    }
}

/// Persistent identity authority kept independently from the disposable FTS
/// database. One document may have several locator aliases (for overlapping
/// roots), while tombstones ensure a new inode at a deleted path gets a new ID.
final class DocumentIdentityStore: @unchecked Sendable {
    enum StoreError: LocalizedError {
        case corruptStore(URL)

        var errorDescription: String? {
            switch self {
            case .corruptStore(let url):
                "Clio's document identity store is unreadable at \(url.path)."
            }
        }
    }

    nonisolated static var defaultStorageURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Clio", isDirectory: true)
            .appendingPathComponent("DocumentIdentities.json")
    }

    static let shared = DocumentIdentityStore()

    private struct State: Codable {
        var locators: [String: UUID] = [:]
        var physicalFiles: [String: UUID] = [:]
        var physicalPaths: [String: String] = [:]
        var tombstones: [String: UUID] = [:]
        var tombstoneOrder: [String] = []

        private enum CodingKeys: String, CodingKey {
            case locators, physicalFiles, physicalPaths, tombstones, tombstoneOrder
        }

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            locators = try values.decodeIfPresent([String: UUID].self, forKey: .locators) ?? [:]
            physicalFiles = try values.decodeIfPresent([String: UUID].self, forKey: .physicalFiles) ?? [:]
            physicalPaths = try values.decodeIfPresent([String: String].self, forKey: .physicalPaths) ?? [:]
            tombstones = try values.decodeIfPresent([String: UUID].self, forKey: .tombstones) ?? [:]
            tombstoneOrder = try values.decodeIfPresent([String].self, forKey: .tombstoneOrder)
                ?? Array(tombstones.keys)
        }
    }

    private let lock = NSLock()
    private let persistenceLock = NSLock()
    private let persistenceQueue = DispatchQueue(
        label: "olympus.clio.document-identity-persistence",
        qos: .utility
    )
    private let storageURL: URL?
    private var state: State
    private var startupError: Error?
    private var pendingPersistence: DispatchWorkItem?
    private var pendingPersistenceToken: UUID?
    private var backgroundPersistenceError: Error?

    static let maximumRetainedTombstones = 1_024

    struct Statistics: Equatable {
        let locators: Int
        let physicalFiles: Int
        let tombstones: Int
    }

    init(storageURL: URL? = DocumentIdentityStore.defaultStorageURL) {
        self.storageURL = storageURL
        guard let storageURL,
              FileManager.default.fileExists(atPath: storageURL.path) else {
            state = State()
            return
        }
        do {
            state = try JSONDecoder().decode(
                State.self,
                from: Data(contentsOf: storageURL)
            )
        } catch {
            state = State()
            startupError = StoreError.corruptStore(storageURL)
        }
    }

    func resolve(_ candidate: DocumentIdentityCandidate) throws -> DocumentID {
        try resolve([candidate])[0]
    }

    func resolve(_ candidates: [DocumentIdentityCandidate]) throws -> [DocumentID] {
        lock.lock()
        defer { lock.unlock() }
        if let startupError { throw startupError }

        var changed = false
        // Update every observed resource path before resolving locators. This
        // lets one scan distinguish a moved live inode from a newly-created
        // inode that reused its old path, regardless of traversal order.
        for candidate in candidates {
            guard let identity = candidate.physicalIdentity,
                  let canonicalPath = candidate.canonicalPath else { continue }
            let key = Self.key(identity)
            if state.physicalPaths[key] != canonicalPath {
                state.physicalPaths[key] = canonicalPath
                changed = true
            }
        }
        var physicalsByDocumentID: [UUID: [(key: String, path: String)]] = [:]
        physicalsByDocumentID.reserveCapacity(state.physicalFiles.count)
        for (key, id) in state.physicalFiles {
            guard let path = state.physicalPaths[key] else { continue }
            physicalsByDocumentID[id, default: []].append((key, path))
        }
        let identifiers = candidates.map { candidate -> DocumentID in
            let locatorKey = Self.key(candidate.locator)
            let physicalKey = candidate.physicalIdentity.map(Self.key)
            let tombstonedID = state.tombstones[locatorKey]
            var physicalID = physicalKey.flatMap { state.physicalFiles[$0] }
            if physicalID == tombstonedID {
                if let physicalKey {
                    state.physicalFiles[physicalKey] = nil
                    state.physicalPaths[physicalKey] = nil
                }
                physicalID = nil
                changed = true
            }

            var locatorID = tombstonedID == nil ? state.locators[locatorKey] : nil
            if let candidateID = locatorID,
               let candidatePath = candidate.canonicalPath,
               physicalsByDocumentID[candidateID, default: []].contains(where: {
                   guard $0.key != physicalKey,
                         $0.path != candidatePath else { return false }
                   return FileManager.default.fileExists(atPath: $0.path)
               }) {
                // The old document is still alive at another path: this path
                // is a distinct recreation, not an alias of that document.
                locatorID = nil
            }
            let proposedID = candidate.preferredID.flatMap { candidateID -> UUID? in
                let preferred = candidateID.rawValue
                if physicalID == preferred || locatorID == preferred { return preferred }
                let claimedByAnotherPhysical = state.physicalFiles.contains {
                    $0.value == preferred && $0.key != physicalKey
                }
                let claimedByAnotherLocator = state.locators.contains {
                    $0.value == preferred && $0.key != locatorKey
                }
                return claimedByAnotherPhysical || claimedByAnotherLocator ? nil : preferred
            }
            let winner = physicalID
                ?? locatorID
                ?? proposedID
                ?? UUID()

            if state.locators[locatorKey] != winner {
                state.locators[locatorKey] = winner
                changed = true
            }
            if let physicalKey,
               bindPhysicalLocked(
                   key: physicalKey,
                   documentID: winner,
                   canonicalPath: candidate.canonicalPath
               ) {
                if let path = candidate.canonicalPath {
                    physicalsByDocumentID[winner, default: []].append((physicalKey, path))
                }
                changed = true
            }
            if removeTombstoneLocked(locatorKey) {
                changed = true
            }
            return DocumentID(rawValue: winner)
        }
        if changed { try persistLocked() }
        return identifiers
    }

    func bind(
        _ documentID: DocumentID,
        locator: DocumentLocator,
        physicalIdentity: PhysicalFileIdentity?,
        canonicalPath: String? = nil
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        if let startupError { throw startupError }
        let locatorKey = Self.key(locator)
        var changed = false
        var requiresImmediatePersistence = false
        if state.locators[locatorKey] != documentID.rawValue {
            state.locators[locatorKey] = documentID.rawValue
            changed = true
            requiresImmediatePersistence = true
        }
        if removeTombstoneLocked(locatorKey) {
            changed = true
            requiresImmediatePersistence = true
        }
        if let physicalIdentity {
            let key = Self.key(physicalIdentity)
            if bindPhysicalLocked(
                key: key,
                documentID: documentID.rawValue,
                canonicalPath: canonicalPath
            ) {
                changed = true
            }
        }
        if changed {
            if requiresImmediatePersistence {
                try persistLocked()
            } else {
                schedulePersistenceLocked()
            }
        }
    }

    func migrate(
        documentID: DocumentID? = nil,
        from source: DocumentLocator,
        to destination: DocumentLocator,
        physicalIdentity: PhysicalFileIdentity?,
        destinationPath: String? = nil
    ) throws -> DocumentID {
        lock.lock()
        defer { lock.unlock() }
        if let startupError { throw startupError }
        let sourceKey = Self.key(source)
        let destinationKey = Self.key(destination)
        let resolved = documentID?.rawValue
            ?? state.locators[sourceKey]
            ?? physicalIdentity.flatMap { state.physicalFiles[Self.key($0)] }
            ?? UUID()
        state.locators[sourceKey] = nil
        markTombstoneLocked(sourceKey, documentID: resolved)
        state.locators[destinationKey] = resolved
        _ = removeTombstoneLocked(destinationKey)
        if let physicalIdentity {
            let key = Self.key(physicalIdentity)
            _ = bindPhysicalLocked(
                key: key,
                documentID: resolved,
                canonicalPath: destinationPath
            )
        }
        _ = pruneOrphanedPhysicalMappingsLocked()
        _ = compactTombstonesLocked()
        try persistLocked()
        return DocumentID(rawValue: resolved)
    }

    func tombstone(_ locator: DocumentLocator, documentID: DocumentID? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        if let startupError { throw startupError }
        let key = Self.key(locator)
        let previous = documentID?.rawValue ?? state.locators[key]
        var changed = state.locators.removeValue(forKey: key) != nil
        if let previous { changed = markTombstoneLocked(key, documentID: previous) || changed }
        changed = pruneOrphanedPhysicalMappingsLocked() || changed
        changed = compactTombstonesLocked() || changed
        if changed { try persistLocked() }
    }

    func tombstoneDescendants(
        workspaceID: WorkspaceID,
        relativePath: String
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        if let startupError { throw startupError }
        let prefix = workspaceID.rawValue.uuidString + "\u{0}"
        let directory = relativePath.hasSuffix("/") ? relativePath : relativePath + "/"
        let keys = state.locators.keys.filter {
            guard $0.hasPrefix(prefix) else { return false }
            let path = String($0.dropFirst(prefix.count))
            return path == relativePath || path.hasPrefix(directory)
        }
        guard !keys.isEmpty else { return }
        for key in keys {
            if let id = state.locators.removeValue(forKey: key) {
                markTombstoneLocked(key, documentID: id)
            }
        }
        _ = pruneOrphanedPhysicalMappingsLocked()
        _ = compactTombstonesLocked()
        try persistLocked()
    }

    func storedDocumentID(for locator: DocumentLocator) -> DocumentID? {
        lock.lock()
        defer { lock.unlock() }
        guard state.tombstones[Self.key(locator)] == nil,
              let value = state.locators[Self.key(locator)] else { return nil }
        return DocumentID(rawValue: value)
    }

    func statistics() -> Statistics {
        lock.lock()
        defer { lock.unlock() }
        return Statistics(
            locators: state.locators.count,
            physicalFiles: state.physicalFiles.count,
            tombstones: state.tombstones.count
        )
    }

    func flushPendingPersistence() throws {
        lock.lock()
        defer { lock.unlock() }
        if let startupError { throw startupError }
        try persistLocked()
    }
}

private extension DocumentIdentityStore {
    static func key(_ locator: DocumentLocator) -> String {
        locator.workspaceID.rawValue.uuidString + "\u{0}" + locator.relativePath
    }

    static func key(_ identity: PhysicalFileIdentity) -> String {
        switch identity {
        case .resource(let volumeIdentifier, let fileResourceIdentifier):
            "resource\u{0}\(volumeIdentifier)\u{0}\(fileResourceIdentifier)"
        case .path(let canonicalPath):
            "path\u{0}\(canonicalPath)"
        }
    }

    func bindPhysicalLocked(
        key: String,
        documentID: UUID,
        canonicalPath: String?
    ) -> Bool {
        var changed = false
        if let canonicalPath {
            let staleKeys = state.physicalPaths.compactMap { existingKey, path in
                path == canonicalPath && existingKey != key ? existingKey : nil
            }
            for staleKey in staleKeys {
                state.physicalFiles[staleKey] = nil
                state.physicalPaths[staleKey] = nil
                changed = true
            }
        }
        if state.physicalFiles[key] != documentID {
            state.physicalFiles[key] = documentID
            changed = true
        }
        if let canonicalPath, state.physicalPaths[key] != canonicalPath {
            state.physicalPaths[key] = canonicalPath
            changed = true
        }
        return changed
    }

    func pruneOrphanedPhysicalMappingsLocked() -> Bool {
        let liveIDs = Set(state.locators.values)
        let staleKeys = state.physicalFiles.compactMap {
            liveIDs.contains($0.value) ? nil : $0.key
        }
        for key in staleKeys {
            state.physicalFiles[key] = nil
            state.physicalPaths[key] = nil
        }
        return !staleKeys.isEmpty
    }

    @discardableResult
    func markTombstoneLocked(_ key: String, documentID: UUID) -> Bool {
        let changed = state.tombstones[key] != documentID
        state.tombstones[key] = documentID
        state.tombstoneOrder.removeAll { $0 == key }
        state.tombstoneOrder.append(key)
        return changed
    }

    func removeTombstoneLocked(_ key: String) -> Bool {
        guard state.tombstones.removeValue(forKey: key) != nil else { return false }
        state.tombstoneOrder.removeAll { $0 == key }
        return true
    }

    func compactTombstonesLocked() -> Bool {
        let original = state.tombstoneOrder
        state.tombstoneOrder = state.tombstoneOrder.filter {
            state.tombstones[$0] != nil
        }
        while state.tombstoneOrder.count > Self.maximumRetainedTombstones {
            state.tombstones[state.tombstoneOrder.removeFirst()] = nil
        }
        return original != state.tombstoneOrder
    }

    func persistLocked() throws {
        guard let storageURL else { return }
        persistenceLock.lock()
        pendingPersistence?.cancel()
        pendingPersistence = nil
        pendingPersistenceToken = nil
        persistenceLock.unlock()
        let snapshot = state
        try persistenceQueue.sync {
            try Self.write(snapshot, to: storageURL)
        }
        persistenceLock.lock()
        backgroundPersistenceError = nil
        persistenceLock.unlock()
    }

    func schedulePersistenceLocked() {
        guard storageURL != nil else { return }
        let token = UUID()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.persistenceLock.lock()
            let isCurrent = self.pendingPersistenceToken == token
            self.persistenceLock.unlock()
            guard isCurrent else { return }

            self.lock.lock()
            let snapshot = self.state
            self.lock.unlock()

            self.persistenceLock.lock()
            guard self.pendingPersistenceToken == token,
                  let storageURL = self.storageURL else {
                self.persistenceLock.unlock()
                return
            }
            self.pendingPersistence = nil
            self.pendingPersistenceToken = nil
            self.persistenceQueue.async { [weak self] in
                guard let self else { return }
                do {
                    try Self.write(snapshot, to: storageURL)
                } catch {
                    self.persistenceLock.lock()
                    self.backgroundPersistenceError = error
                    self.persistenceLock.unlock()
                }
            }
            self.persistenceLock.unlock()
        }
        persistenceLock.lock()
        pendingPersistence?.cancel()
        pendingPersistence = work
        pendingPersistenceToken = token
        persistenceLock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .milliseconds(100),
            execute: work
        )
    }

    private static func write(_ state: State, to storageURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: storageURL, options: .atomic)
    }
}
