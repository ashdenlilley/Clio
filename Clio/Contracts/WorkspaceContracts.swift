import Foundation

struct WorkspaceDescriptor: Codable, Hashable, Sendable, Identifiable {
    let id: WorkspaceID
    let rootURL: URL
    var displayName: String

    init(id: WorkspaceID = WorkspaceID(), rootURL: URL, displayName: String? = nil) {
        self.id = id
        self.rootURL = rootURL.standardizedFileURL
        self.displayName = displayName ?? rootURL.lastPathComponent
    }
}

enum WorkspaceEventKind: String, Codable, Hashable, Sendable {
    case created
    case modified
    case moved
    case deleted
    case rootChanged
    case rescanRequired
    case accessLost
    case error
}

enum WorkspaceEventOrigin: String, Codable, Hashable, Sendable {
    case clio
    case external
    case unknown
}

struct WorkspaceEvent: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let workspaceID: WorkspaceID
    let kind: WorkspaceEventKind
    let fileURL: URL?
    let previousFileURL: URL?
    let observedAt: Date
    let origin: WorkspaceEventOrigin
    let selfWriteToken: UUID?

    init(
        id: UUID = UUID(),
        workspaceID: WorkspaceID,
        kind: WorkspaceEventKind,
        fileURL: URL? = nil,
        previousFileURL: URL? = nil,
        observedAt: Date = Date(),
        origin: WorkspaceEventOrigin = .unknown,
        selfWriteToken: UUID? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.kind = kind
        self.fileURL = fileURL
        self.previousFileURL = previousFileURL
        self.observedAt = observedAt
        self.origin = origin
        self.selfWriteToken = selfWriteToken
    }
}

protocol WorkspaceEventSource: Sendable {
    func events() async -> AsyncStream<WorkspaceEvent>
}

enum BuiltInExclusion: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case gitMetadata
    case nodeModules
    case buildOutput
    case caches

    var id: Self { self }

    var displayName: String {
        switch self {
        case .gitMetadata: ".git"
        case .nodeModules: "node_modules"
        case .buildOutput: "Build output"
        case .caches: "Caches"
        }
    }
}

struct DiscoveryPolicy: Codable, Hashable, Sendable {
    var respectsGitIgnore: Bool
    var includesHiddenFiles: Bool
    var includesTextFiles: Bool
    var enabledBuiltIns: Set<BuiltInExclusion>
    var additionalPatterns: [String]

    static let `default` = Self(
        respectsGitIgnore: true,
        includesHiddenFiles: false,
        includesTextFiles: true,
        enabledBuiltIns: Set(BuiltInExclusion.allCases),
        additionalPatterns: []
    )
}

struct ExclusionReason: Codable, Hashable, Sendable {
    let pattern: String
    let sourceURL: URL?
    let line: Int?
    let builtIn: BuiltInExclusion?
}

struct WorkspaceFile: Codable, Hashable, Sendable, Identifiable {
    let documentID: DocumentID
    let locator: DocumentLocator
    let relativePath: String
    let modificationDate: Date
    let byteCount: Int64
    let exclusionReason: ExclusionReason?

    var id: DocumentID { documentID }
}

struct WorkspaceTreeSnapshot: Codable, Hashable, Sendable {
    let workspace: WorkspaceDescriptor
    let files: [WorkspaceFile]
    let generatedAt: Date
    let isComplete: Bool
}

struct WorkspaceSearchQuery: Codable, Hashable, Sendable {
    var text: String
    var workspaceFilter: WorkspaceID?
    var includesIgnored: Bool
    var limit: Int

    init(
        text: String,
        workspaceFilter: WorkspaceID? = nil,
        includesIgnored: Bool = false,
        limit: Int = 100
    ) {
        self.text = text
        self.workspaceFilter = workspaceFilter
        self.includesIgnored = includesIgnored
        self.limit = max(1, min(limit, 500))
    }
}

struct WorkspaceSearchResult: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let documentID: DocumentID
    let workspaceID: WorkspaceID
    let relativePath: String
    let lineNumber: Int?
    let excerpt: String?
    let documentMatchRange: UTF16Range?
    let excerptMatchRange: UTF16Range?
    let score: Double
    let exclusionReason: ExclusionReason?

    init(
        id: UUID = UUID(),
        documentID: DocumentID,
        workspaceID: WorkspaceID,
        relativePath: String,
        lineNumber: Int? = nil,
        excerpt: String? = nil,
        documentMatchRange: UTF16Range? = nil,
        excerptMatchRange: UTF16Range? = nil,
        score: Double,
        exclusionReason: ExclusionReason? = nil
    ) {
        self.id = id
        self.documentID = documentID
        self.workspaceID = workspaceID
        self.relativePath = relativePath
        self.lineNumber = lineNumber
        self.excerpt = excerpt
        self.documentMatchRange = documentMatchRange
        self.excerptMatchRange = excerptMatchRange
        self.score = score
        self.exclusionReason = exclusionReason
    }
}

struct SearchBatch: Sendable, Equatable {
    let results: [WorkspaceSearchResult]
    let isFinal: Bool

    init(results: [WorkspaceSearchResult], isFinal: Bool) {
        self.results = results
        self.isFinal = isFinal
    }
}

protocol SearchIndexing: Sendable {
    func rebuild(workspaces: [WorkspaceDescriptor], policy: DiscoveryPolicy) async throws
    func apply(_ events: [WorkspaceEvent]) async throws
    func quickOpen(_ query: WorkspaceSearchQuery) async -> AsyncThrowingStream<SearchBatch, Error>
    func search(_ query: WorkspaceSearchQuery) async -> AsyncThrowingStream<SearchBatch, Error>
}
