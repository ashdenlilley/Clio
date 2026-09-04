import Foundation

struct WorkspaceID: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var id: UUID { rawValue }
}

struct DocumentID: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var id: UUID { rawValue }
}

/// Runtime-only identity used by the buffer registry to coalesce multiple
/// authorized references to the same physical file. It is deliberately not
/// persisted: atomic replacement may change a file resource identifier.
enum PhysicalFileIdentity: Hashable, Sendable {
    case resource(volumeIdentifier: String, fileResourceIdentifier: String)
    case path(canonicalPath: String)

    static func authorizedFile(at url: URL) -> Self {
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [
            .fileResourceIdentifierKey,
            .volumeIdentifierKey,
        ]

        if let values = try? canonicalURL.resourceValues(forKeys: keys),
           let volumeIdentifier = values.volumeIdentifier,
           let fileIdentifier = values.fileResourceIdentifier {
            return .resource(
                volumeIdentifier: stableDescription(volumeIdentifier),
                fileResourceIdentifier: stableDescription(fileIdentifier)
            )
        }

        return .path(canonicalPath: canonicalURL.path)
    }

    private static func stableDescription(_ value: Any) -> String {
        if let data = value as? Data {
            return data.base64EncodedString()
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return String(describing: value)
    }

}

struct DocumentLocator: Codable, Hashable, Sendable {
    enum ValidationError: LocalizedError, Equatable {
        case emptyPath
        case absolutePath(String)
        case pathEscapesWorkspace(String)

        var errorDescription: String? {
            switch self {
            case .emptyPath: "A document path cannot be empty."
            case .absolutePath(let path): "A document path must be relative: \(path)"
            case .pathEscapesWorkspace(let path): "A document path cannot leave its workspace: \(path)"
            }
        }
    }

    let workspaceID: WorkspaceID
    let relativePath: String

    init(workspaceID: WorkspaceID, relativePath: String) throws {
        guard !relativePath.isEmpty else { throw ValidationError.emptyPath }
        guard !relativePath.hasPrefix("/") else {
            throw ValidationError.absolutePath(relativePath)
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              !components.contains(".."),
              !components.contains(".") else {
            throw ValidationError.pathEscapesWorkspace(relativePath)
        }
        self.workspaceID = workspaceID
        self.relativePath = components.joined(separator: "/")
    }


    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let workspaceID = try container.decode(WorkspaceID.self, forKey: .workspaceID)
        let relativePath = try container.decode(String.self, forKey: .relativePath)
        try self.init(workspaceID: workspaceID, relativePath: relativePath)
    }
}

struct DiskRevision: Codable, Hashable, Sendable {
    let modificationDate: Date
    let byteCount: Int64
    let contentDigest: String

    init(modificationDate: Date, byteCount: Int64, contentDigest: String) {
        self.modificationDate = modificationDate
        self.byteCount = byteCount
        self.contentDigest = contentDigest
    }
}

struct DiskSnapshot: Codable, Hashable, Sendable {
    let locator: DocumentLocator
    let revision: DiskRevision
    let source: String
    let readAt: Date
}

enum DocumentSizeMode: String, Codable, Hashable, Sendable {
    case full
    case safeLargeFile
    case unsupported

    static func mode(forUTF8ByteCount byteCount: Int) -> Self {
        if byteCount <= PerformanceContract.fullMarkdownByteLimit {
            return .full
        }
        if byteCount <= PerformanceContract.safeLargeFileByteLimit {
            return .safeLargeFile
        }
        return .unsupported
    }
}

struct DocumentTextSnapshot: Sendable {
    let documentID: DocumentID
    let generation: BufferGeneration
    let filename: String
    let source: String
    let sourceFingerprint: String
    let sizeMode: DocumentSizeMode

    init(
        documentID: DocumentID,
        generation: BufferGeneration,
        filename: String,
        source: String,
        sourceFingerprint: String
    ) {
        self.documentID = documentID
        self.generation = generation
        self.filename = filename
        self.source = source
        self.sourceFingerprint = sourceFingerprint
        sizeMode = .mode(forUTF8ByteCount: source.utf8.count)
    }
}

struct BufferGeneration: Codable, Hashable, Sendable {
    let bufferID: UUID
    let revision: UInt64

    init(bufferID: UUID = UUID(), revision: UInt64 = 0) {
        self.bufferID = bufferID
        self.revision = revision
    }
}

enum ConflictChoice: String, Codable, CaseIterable, Hashable, Sendable {
    case keepClio
    case loadExternal
    case keepBoth
}

enum CollisionChoice: String, Codable, CaseIterable, Hashable, Sendable {
    case cancel
    case replace
    case keepBoth
}

struct ConflictSide: Codable, Hashable, Sendable {
    let modificationDate: Date
    let revision: DiskRevision?
    let source: String
}

struct DocumentConflict: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let documentID: DocumentID
    let locator: DocumentLocator
    let clio: ConflictSide
    let external: ConflictSide
    let additionalExternalVersions: [ConflictSide]?

    init(
        id: UUID = UUID(),
        documentID: DocumentID,
        locator: DocumentLocator,
        clio: ConflictSide,
        external: ConflictSide,
        additionalExternalVersions: [ConflictSide]? = nil
    ) {
        self.id = id
        self.documentID = documentID
        self.locator = locator
        self.clio = clio
        self.external = external
        self.additionalExternalVersions = additionalExternalVersions
    }
}

enum SaveOutcome: Sendable, Equatable {
    case saved(locator: DocumentLocator, revision: DiskRevision)
    case conflict(DocumentConflict)
    case collision(FileCollision)
    case deleted
}

struct NewDocumentTarget: Sendable, Equatable {
    let workspaceID: WorkspaceID
    let parentRelativePath: String
    let preferredFilename: String
    let collisionChoice: CollisionChoice?
}

enum SaveTarget: Sendable, Equatable {
    case existing(DocumentLocator)
    case new(NewDocumentTarget)
}

struct FileCollision: Sendable, Equatable, Identifiable {
    let id: UUID
    let proposedLocator: DocumentLocator
    let existingRevision: DiskRevision?

    init(
        id: UUID = UUID(),
        proposedLocator: DocumentLocator,
        existingRevision: DiskRevision?
    ) {
        self.id = id
        self.proposedLocator = proposedLocator
        self.existingRevision = existingRevision
    }
}

struct SaveRequest: Sendable {
    let documentID: DocumentID
    let target: SaveTarget
    let generation: BufferGeneration
    let expectedDiskRevision: DiskRevision?
    let source: String
    let selfWriteToken: UUID
}

struct ConflictResolutionRequest: Sendable {
    let conflictID: UUID
    let choice: ConflictChoice
    let currentLocalSnapshot: DocumentTextSnapshot
    let expectedExternalRevision: DiskRevision
}

struct FileMoveRequest: Sendable, Equatable {
    let documentID: DocumentID
    let source: DocumentLocator
    let destinationWorkspaceID: WorkspaceID
    let destinationParentRelativePath: String
    let preferredFilename: String
    let collisionChoice: CollisionChoice?
}

enum FileMutationOutcome: Sendable, Equatable {
    case completed(DocumentLocator)
    case collision(FileCollision)
    case cancelled
}

struct RecoveryReceipt: Codable, Hashable, Sendable {
    let documentID: DocumentID
    let recoveryURL: URL
    let createdAt: Date
}

enum DocumentSyncState: Sendable, Equatable {
    case clean(DiskRevision)
    case dirty(base: DiskRevision?)
    case saving(base: DiskRevision?, generation: BufferGeneration)
    case conflicted(DocumentConflict)
    case unbacked(previous: DocumentLocator?)
}

protocol FileRepositoryProtocol: Sendable {
    func read(_ locator: DocumentLocator) async throws -> DiskSnapshot
    func save(_ request: SaveRequest) async throws -> SaveOutcome
    func resolve(_ request: ConflictResolutionRequest) async throws -> SaveOutcome
    func move(_ request: FileMoveRequest) async throws -> FileMutationOutcome
    func moveToTrash(_ locator: DocumentLocator) async throws
}

protocol RecoveryPersisting: Sendable {
    func preserve(
        documentID: DocumentID,
        filename: String,
        source: String,
        date: Date
    ) async throws -> RecoveryReceipt
    func prune(olderThan date: Date) async throws
}

@MainActor
protocol DocumentBufferRegistering: AnyObject {
    func documentID(
        for identity: PhysicalFileIdentity,
        locator: DocumentLocator
    ) -> DocumentID
    func updateAliases(
        for documentID: DocumentID,
        identity: PhysicalFileIdentity,
        locator: DocumentLocator
    )
}
