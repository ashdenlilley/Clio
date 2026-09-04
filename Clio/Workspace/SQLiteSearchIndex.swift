import Foundation
import SQLite3

actor SQLiteSearchIndex: SearchIndexing {
    enum IndexError: LocalizedError {
        case open(String)
        case sqlite(String)
        case corruptIdentity(String)

        var errorDescription: String? {
            switch self {
            case .open(let message): "Could not open Clio's search index: \(message)"
            case .sqlite(let message): "Clio's search index failed: \(message)"
            case .corruptIdentity(let value): "Clio's search index contains an invalid identity: \(value)"
            }
        }
    }

    nonisolated static var defaultDatabaseURL: URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("Clio", isDirectory: true)
            .appendingPathComponent("SearchIndex.sqlite3")
    }

    private let databaseURL: URL
    private let fileManager: FileManager
    private let scanner: WorkspaceScanner
    private var database: OpaquePointer?
    private var indexedWorkspaces: [WorkspaceDescriptor] = []
    private var discoveryPolicy = DiscoveryPolicy.default
    private var ignoredTierLoaded = false
    private var indexingOperationID = UUID()

    init(
        databaseURL: URL = SQLiteSearchIndex.defaultDatabaseURL,
        fileManager: FileManager = .default
    ) throws {
        self.databaseURL = databaseURL
        self.fileManager = fileManager
        scanner = WorkspaceScanner(fileManager: fileManager)

        try fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var openedDatabase: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &openedDatabase,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let openedDatabase else {
            let message = openedDatabase.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown SQLite error"
            sqlite3_close(openedDatabase)
            throw IndexError.open(message)
        }
        database = openedDatabase
        try Self.configure(openedDatabase)
    }

    deinit {
        sqlite3_close(database)
    }

    func rebuild(
        workspaces: [WorkspaceDescriptor],
        policy: DiscoveryPolicy
    ) async throws {
        let operationID = UUID()
        indexingOperationID = operationID
        let normalizedWorkspaces = Self.removingOverlappingRoots(workspaces)
        var snapshots: [(WorkspaceDescriptor, WorkspaceTreeSnapshot)] = []
        snapshots.reserveCapacity(normalizedWorkspaces.count)

        for workspace in normalizedWorkspaces {
            try Task.checkCancellation()
            let snapshot = try await scanner.scan(
                workspace: workspace,
                policy: policy,
                includesIgnored: false
            )
            snapshots.append((workspace, snapshot))
        }
        try Task.checkCancellation()
        guard indexingOperationID == operationID else { throw CancellationError() }

        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute("DELETE FROM documents")

            for (workspace, snapshot) in snapshots {
                for file in snapshot.files {
                    try Task.checkCancellation()
                    try index(file: file, workspace: workspace)
                }
            }
            try execute("COMMIT")
            indexedWorkspaces = normalizedWorkspaces
            discoveryPolicy = policy
            ignoredTierLoaded = false
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func apply(_ events: [WorkspaceEvent]) async throws {
        guard !events.isEmpty else { return }
        let affectedIDs = Set(events.map(\.workspaceID))
        let affected = indexedWorkspaces.filter { affectedIDs.contains($0.id) }
        guard !affected.isEmpty else { return }

        if events.contains(where: Self.requiresFullRebuild) {
            try await rebuild(workspaces: indexedWorkspaces, policy: discoveryPolicy)
            return
        }

        let operationID = UUID()
        indexingOperationID = operationID
        var updates: [IndexUpdate] = []
        for event in events {
            try Task.checkCancellation()
            guard let workspace = affected.first(where: { $0.id == event.workspaceID }) else {
                continue
            }
            let previousPath = event.previousFileURL.flatMap {
                Self.relativePath(for: $0, workspace: workspace)
            }
            let currentPath = event.fileURL.flatMap {
                Self.relativePath(for: $0, workspace: workspace)
            }
            let file: WorkspaceFile?
            if let fileURL = event.fileURL,
               event.kind != .deleted,
               Self.isSupportedEventURL(fileURL) {
                file = try await scanner.file(
                    at: fileURL,
                    workspace: workspace,
                    policy: discoveryPolicy,
                    includesIgnored: ignoredTierLoaded
                )
            } else {
                file = nil
            }
            updates.append(
                IndexUpdate(
                    workspace: workspace,
                    removedRelativePath: previousPath ?? (event.kind == .deleted ? currentPath : nil),
                    movedFromRelativePath: event.kind == .moved ? previousPath : nil,
                    file: file,
                    currentRelativePath: currentPath
                )
            )
        }
        try Task.checkCancellation()
        guard indexingOperationID == operationID else { throw CancellationError() }

        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            for update in updates {
                if let removedRelativePath = update.removedRelativePath {
                    try deleteDocument(
                        workspaceID: update.workspace.id,
                        relativePath: removedRelativePath
                    )
                }
                if let movedFrom = update.movedFromRelativePath,
                   let destination = update.file?.relativePath {
                    try deleteDocument(
                        workspaceID: update.workspace.id,
                        relativePath: destination
                    )
                    try migrateIdentity(
                        workspaceID: update.workspace.id,
                        from: movedFrom,
                        to: destination
                    )
                }
                if let file = update.file {
                    try index(file: file, workspace: update.workspace)
                } else if let currentRelativePath = update.currentRelativePath {
                    try deleteDocument(
                        workspaceID: update.workspace.id,
                        relativePath: currentRelativePath
                    )
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func quickOpen(
        _ query: WorkspaceSearchQuery
    ) async -> AsyncThrowingStream<SearchBatch, Error> {
        if query.includesIgnored {
            do {
                try await loadIgnoredTierIfNeeded()
            } catch {
                return Self.failedStream(error)
            }
        }
        return progressiveStream(query: query, mode: .filename)
    }

    func search(
        _ query: WorkspaceSearchQuery
    ) async -> AsyncThrowingStream<SearchBatch, Error> {
        if query.includesIgnored {
            do {
                try await loadIgnoredTierIfNeeded()
            } catch {
                return Self.failedStream(error)
            }
        }
        return progressiveStream(query: query, mode: .content)
    }
}

private extension SQLiteSearchIndex {
    struct IndexUpdate {
        let workspace: WorkspaceDescriptor
        let removedRelativePath: String?
        let movedFromRelativePath: String?
        let file: WorkspaceFile?
        let currentRelativePath: String?
    }

    enum QueryMode {
        case filename
        case content
    }

    static let transientDestructor = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    static func configure(_ database: OpaquePointer) throws {
        let statements = [
            "PRAGMA journal_mode=WAL",
            "PRAGMA synchronous=NORMAL",
            "PRAGMA temp_store=MEMORY",
            "PRAGMA foreign_keys=ON",
            "PRAGMA recursive_triggers=ON",
            """
            CREATE TABLE IF NOT EXISTS documents (
                document_id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                content TEXT NOT NULL,
                modification_time REAL NOT NULL,
                byte_count INTEGER NOT NULL,
                excluded_pattern TEXT,
                excluded_source TEXT,
                excluded_line INTEGER,
                excluded_builtin TEXT,
                UNIQUE(workspace_id, relative_path)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS document_identities (
                workspace_id TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                document_id TEXT NOT NULL UNIQUE,
                PRIMARY KEY(workspace_id, relative_path)
            )
            """,
            "CREATE INDEX IF NOT EXISTS documents_path ON documents(workspace_id, relative_path COLLATE NOCASE)",
        ]

        for statement in statements {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(database, statement, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) }
                    ?? String(cString: sqlite3_errmsg(database))
                sqlite3_free(error)
                throw IndexError.sqlite(message)
            }
        }

        try addColumnIfMissing(
            "excluded_builtin",
            definition: "TEXT",
            to: "documents",
            database: database
        )

        let hasCompatibleFTS = ftsUsesExternalContent(database: database)
        if !hasCompatibleFTS {
            for statement in [
                "DROP TRIGGER IF EXISTS documents_fts_insert",
                "DROP TRIGGER IF EXISTS documents_fts_delete",
                "DROP TRIGGER IF EXISTS documents_fts_update",
                "DROP TABLE IF EXISTS documents_fts",
            ] {
                try execute(statement, database: database)
            }
        }

        for statement in [
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5(
                relative_path,
                content,
                content = 'documents',
                content_rowid = 'rowid',
                tokenize = 'unicode61 remove_diacritics 2'
            )
            """,
            """
            CREATE TRIGGER IF NOT EXISTS documents_fts_insert AFTER INSERT ON documents BEGIN
                INSERT INTO documents_fts(rowid, relative_path, content)
                VALUES (new.rowid, new.relative_path, new.content);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS documents_fts_delete AFTER DELETE ON documents BEGIN
                INSERT INTO documents_fts(documents_fts, rowid, relative_path, content)
                VALUES ('delete', old.rowid, old.relative_path, old.content);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS documents_fts_update AFTER UPDATE ON documents BEGIN
                INSERT INTO documents_fts(documents_fts, rowid, relative_path, content)
                VALUES ('delete', old.rowid, old.relative_path, old.content);
                INSERT INTO documents_fts(rowid, relative_path, content)
                VALUES (new.rowid, new.relative_path, new.content);
            END
            """,
        ] {
            try execute(statement, database: database)
        }
        if !hasCompatibleFTS {
            try execute(
                "INSERT INTO documents_fts(documents_fts) VALUES ('rebuild')",
                database: database
            )
        }
    }

    static func removingOverlappingRoots(
        _ workspaces: [WorkspaceDescriptor]
    ) -> [WorkspaceDescriptor] {
        workspaces
            .reduce(into: []) { result, candidate in
                let candidatePath = candidate.rootURL.standardizedFileURL.path
                guard !result.contains(where: {
                    let rootPath = $0.rootURL.standardizedFileURL.path
                    return candidatePath == rootPath
                }) else { return }
                result.append(candidate)
            }
    }

    func loadIgnoredTierIfNeeded() async throws {
        guard !ignoredTierLoaded else { return }
        let operationID = UUID()
        indexingOperationID = operationID
        var snapshots: [(WorkspaceDescriptor, WorkspaceTreeSnapshot)] = []

        for workspace in indexedWorkspaces {
            try Task.checkCancellation()
            let snapshot = try await scanner.scan(
                workspace: workspace,
                policy: discoveryPolicy,
                includesIgnored: true
            )
            snapshots.append((workspace, snapshot))
        }
        try Task.checkCancellation()
        guard indexingOperationID == operationID else { throw CancellationError() }

        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            for (workspace, snapshot) in snapshots {
                for file in snapshot.files where file.exclusionReason != nil {
                    try Task.checkCancellation()
                    try index(file: file, workspace: workspace)
                }
            }
            try execute("COMMIT")
            ignoredTierLoaded = true
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    static func failedStream(_ error: Error) -> AsyncThrowingStream<SearchBatch, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }

    static func requiresFullRebuild(_ event: WorkspaceEvent) -> Bool {
        switch event.kind {
        case .rootChanged, .rescanRequired, .accessLost, .error:
            return true
        case .created, .modified, .moved, .deleted:
            break
        }

        let urls = [event.fileURL, event.previousFileURL].compactMap { $0 }
        if urls.contains(where: { $0.lastPathComponent == ".gitignore" }) {
            return true
        }
        if urls.contains(where: { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }) {
            return true
        }
        if event.kind == .deleted,
           let url = event.fileURL,
           !isSupportedEventURL(url) {
            return true
        }
        return false
    }

    static func isSupportedEventURL(_ url: URL) -> Bool {
        ["md", "markdown", "txt"].contains(url.pathExtension.lowercased())
    }

    static func relativePath(
        for url: URL,
        workspace: WorkspaceDescriptor
    ) -> String? {
        let rootPath = workspace.rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    func progressiveStream(
        query: WorkspaceSearchQuery,
        mode: QueryMode
    ) -> AsyncThrowingStream<SearchBatch, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    let firstLimit = min(20, query.limit)
                    let first = try self.results(
                        for: query,
                        mode: mode,
                        limit: firstLimit
                    )
                    continuation.yield(
                        SearchBatch(
                            results: first,
                            isFinal: query.limit <= firstLimit || first.count < firstLimit
                        )
                    )

                    if query.limit > firstLimit, first.count == firstLimit {
                        try Task.checkCancellation()
                        let settled = try self.results(
                            for: query,
                            mode: mode,
                            limit: query.limit
                        )
                        continuation.yield(SearchBatch(results: settled, isFinal: true))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func results(
        for query: WorkspaceSearchQuery,
        mode: QueryMode,
        limit: Int
    ) throws -> [WorkspaceSearchResult] {
        let results: [WorkspaceSearchResult] = switch mode {
        case .filename:
            try filenameResults(for: query, limit: limit)
        case .content:
            try contentResults(for: query, limit: limit)
        }
        return query.workspaceFilter == nil
            ? deduplicatingPhysicalFiles(results)
            : results
    }

    func deduplicatingPhysicalFiles(
        _ results: [WorkspaceSearchResult]
    ) -> [WorkspaceSearchResult] {
        let roots = Dictionary(uniqueKeysWithValues: indexedWorkspaces.map { ($0.id, $0.rootURL) })
        var positions: [String: Int] = [:]
        var unique: [WorkspaceSearchResult] = []
        for result in results {
            guard let rootURL = roots[result.workspaceID] else { continue }
            let physicalPath = rootURL.appendingPathComponent(result.relativePath)
                .standardizedFileURL.path
            if let position = positions[physicalPath] {
                let existing = unique[position]
                let existingRootLength = roots[existing.workspaceID]?.path.count ?? 0
                if rootURL.path.count > existingRootLength {
                    unique[position] = result
                }
            } else {
                positions[physicalPath] = unique.count
                unique.append(result)
            }
        }
        return unique
    }

    func filenameResults(
        for query: WorkspaceSearchQuery,
        limit: Int
    ) throws -> [WorkspaceSearchResult] {
        var conditions = ["relative_path LIKE ? ESCAPE '\\' COLLATE NOCASE"]
        var bindings = ["%\(Self.escapedLike(query.text))%"]
        appendSharedFilters(query, conditions: &conditions, bindings: &bindings)
        bindings.append(String(limit))
        let sql = """
        SELECT document_id, workspace_id, relative_path,
               excluded_pattern, excluded_source, excluded_line, excluded_builtin
        FROM documents
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY
            CASE WHEN relative_path LIKE ? COLLATE NOCASE THEN 0 ELSE 1 END,
            length(relative_path),
            relative_path COLLATE NOCASE
        LIMIT ?
        """
        bindings.insert("\(Self.escapedLike(query.text))%", at: bindings.count - 1)

        return try queryRows(sql: sql, bindings: bindings) { statement in
            let documentID = try Self.documentID(column: 0, statement: statement)
            let workspaceID = try Self.workspaceID(column: 1, statement: statement)
            let path = Self.text(column: 2, statement: statement)
            let match = (path as NSString).range(
                of: query.text,
                options: [.caseInsensitive, .diacriticInsensitive]
            )
            return WorkspaceSearchResult(
                id: documentID.rawValue,
                documentID: documentID,
                workspaceID: workspaceID,
                relativePath: path,
                documentMatchRange: match.location == NSNotFound
                    ? nil
                    : UTF16Range(location: match.location, length: match.length),
                excerptMatchRange: match.location == NSNotFound
                    ? nil
                    : UTF16Range(location: match.location, length: match.length),
                score: path.lowercased().hasPrefix(query.text.lowercased()) ? 2 : 1,
                exclusionReason: Self.exclusionReason(statement: statement, startColumn: 3)
            )
        }
    }

    func contentResults(
        for query: WorkspaceSearchQuery,
        limit: Int
    ) throws -> [WorkspaceSearchResult] {
        let terms = Self.queryTerms(query.text)
        guard let firstTerm = terms.first,
              let ftsQuery = Self.ftsQuery(terms) else {
            return try filenameResults(for: query, limit: limit)
        }
        var conditions = ["documents_fts MATCH ?"]
        var bindings = [firstTerm, ftsQuery]
        if let workspaceFilter = query.workspaceFilter {
            conditions.append("d.workspace_id = ?")
            bindings.append(workspaceFilter.rawValue.uuidString)
        }
        if !query.includesIgnored {
            conditions.append("d.excluded_pattern IS NULL")
        }
        bindings.append(String(limit))
        let sql = """
        SELECT d.document_id, d.workspace_id, d.relative_path,
               substr(
                   d.content,
                   max(1, instr(lower(d.content), lower(?)) - 240),
                   1024
               ),
               d.excluded_pattern, d.excluded_source, d.excluded_line, d.excluded_builtin,
               bm25(documents_fts)
        FROM documents_fts
        JOIN documents d ON d.rowid = documents_fts.rowid
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY bm25(documents_fts), d.relative_path COLLATE NOCASE
        LIMIT ?
        """

        return try queryRows(sql: sql, bindings: bindings) { statement in
            let documentID = try Self.documentID(column: 0, statement: statement)
            let workspaceID = try Self.workspaceID(column: 1, statement: statement)
            let path = Self.text(column: 2, statement: statement)
            let excerpt = Self.text(column: 3, statement: statement)
            let excerptRange = Self.firstMatchRange(in: excerpt, terms: terms)
            return WorkspaceSearchResult(
                id: documentID.rawValue,
                documentID: documentID,
                workspaceID: workspaceID,
                relativePath: path,
                excerpt: excerpt,
                excerptMatchRange: excerptRange,
                score: -sqlite3_column_double(statement, 8),
                exclusionReason: Self.exclusionReason(statement: statement, startColumn: 4)
            )
        }
    }

    func appendSharedFilters(
        _ query: WorkspaceSearchQuery,
        conditions: inout [String],
        bindings: inout [String]
    ) {
        if let workspaceFilter = query.workspaceFilter {
            conditions.append("workspace_id = ?")
            bindings.append(workspaceFilter.rawValue.uuidString)
        }
        if !query.includesIgnored {
            conditions.append("excluded_pattern IS NULL")
        }
    }

    func index(file: WorkspaceFile, workspace: WorkspaceDescriptor) throws {
        guard file.byteCount <= Int64(PerformanceContract.safeLargeFileByteLimit) else { return }
        let fileURL = workspace.rootURL.appendingPathComponent(file.relativePath)
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let documentID = try persistentDocumentID(
            workspaceID: workspace.id,
            relativePath: file.relativePath,
            proposedID: file.documentID
        )
        try deleteDocument(documentID: documentID)

        let insertDocument = """
        INSERT OR REPLACE INTO documents (
            document_id, workspace_id, relative_path, content,
            modification_time, byte_count, excluded_pattern, excluded_source,
            excluded_line, excluded_builtin
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        try executePrepared(
            sql: insertDocument,
            bindings: [
                documentID.rawValue.uuidString,
                workspace.id.rawValue.uuidString,
                file.relativePath,
                content,
                String(file.modificationDate.timeIntervalSince1970),
                String(file.byteCount),
                file.exclusionReason?.pattern,
                file.exclusionReason?.sourceURL?.path,
                file.exclusionReason?.line.map(String.init),
                file.exclusionReason?.builtIn?.rawValue,
            ]
        )
    }

    func persistentDocumentID(
        workspaceID: WorkspaceID,
        relativePath: String,
        proposedID: DocumentID
    ) throws -> DocumentID {
        let results = try queryRows(
            sql: "SELECT document_id FROM document_identities WHERE workspace_id = ? AND relative_path = ? LIMIT 1",
            bindings: [workspaceID.rawValue.uuidString, relativePath]
        ) { statement in
            try Self.documentID(column: 0, statement: statement)
        }
        if let existing = results.first {
            return existing
        }

        try executePrepared(
            sql: "INSERT INTO document_identities(workspace_id, relative_path, document_id) VALUES (?, ?, ?)",
            bindings: [
                workspaceID.rawValue.uuidString,
                relativePath,
                proposedID.rawValue.uuidString,
            ]
        )
        return proposedID
    }

    func deleteWorkspace(_ workspaceID: WorkspaceID) throws {
        try executePrepared(
            sql: "DELETE FROM documents WHERE workspace_id = ?",
            bindings: [workspaceID.rawValue.uuidString]
        )
    }

    func deleteDocument(
        workspaceID: WorkspaceID,
        relativePath: String
    ) throws {
        try executePrepared(
            sql: "DELETE FROM documents WHERE workspace_id = ? AND relative_path = ?",
            bindings: [workspaceID.rawValue.uuidString, relativePath]
        )
    }

    func migrateIdentity(
        workspaceID: WorkspaceID,
        from sourcePath: String,
        to destinationPath: String
    ) throws {
        guard sourcePath != destinationPath else { return }
        let identifiers = try queryRows(
            sql: "SELECT document_id FROM document_identities WHERE workspace_id = ? AND relative_path = ?",
            bindings: [workspaceID.rawValue.uuidString, sourcePath]
        ) { Self.text(column: 0, statement: $0) }
        guard let identifier = identifiers.first else { return }

        try executePrepared(
            sql: "DELETE FROM document_identities WHERE workspace_id = ? AND relative_path = ?",
            bindings: [workspaceID.rawValue.uuidString, destinationPath]
        )
        try executePrepared(
            sql: "UPDATE document_identities SET relative_path = ? WHERE workspace_id = ? AND relative_path = ? AND document_id = ?",
            bindings: [
                destinationPath,
                workspaceID.rawValue.uuidString,
                sourcePath,
                identifier,
            ]
        )
    }

    func deleteDocument(documentID: DocumentID) throws {
        try executePrepared(
            sql: "DELETE FROM documents WHERE document_id = ?",
            bindings: [documentID.rawValue.uuidString]
        )
    }

    func execute(_ sql: String) throws {
        guard let database else { throw IndexError.open("database is closed") }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw IndexError.sqlite(message)
        }
    }

    func executePrepared(sql: String, bindings: [String?]) throws {
        _ = try queryRows(sql: sql, bindings: bindings) { _ in () }
    }

    func queryRows<T>(
        sql: String,
        bindings: [String?],
        transform: (OpaquePointer) throws -> T
    ) throws -> [T] {
        try Task.checkCancellation()
        guard let database else { throw IndexError.open("database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw IndexError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            if let value {
                result = value.withCString {
                    sqlite3_bind_text(statement, index, $0, -1, Self.transientDestructor)
                }
            } else {
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else {
                throw IndexError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
        }

        var results: [T] = []
        while true {
            try Task.checkCancellation()
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                results.append(try transform(statement))
            case SQLITE_DONE:
                return results
            default:
                throw IndexError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    static func text(column: Int32, statement: OpaquePointer) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    static func documentID(column: Int32, statement: OpaquePointer) throws -> DocumentID {
        let value = text(column: column, statement: statement)
        guard let id = UUID(uuidString: value) else {
            throw IndexError.corruptIdentity(value)
        }
        return DocumentID(rawValue: id)
    }

    static func workspaceID(column: Int32, statement: OpaquePointer) throws -> WorkspaceID {
        let value = text(column: column, statement: statement)
        guard let id = UUID(uuidString: value) else {
            throw IndexError.corruptIdentity(value)
        }
        return WorkspaceID(rawValue: id)
    }

    static func exclusionReason(
        statement: OpaquePointer,
        startColumn: Int32
    ) -> ExclusionReason? {
        guard sqlite3_column_type(statement, startColumn) != SQLITE_NULL else { return nil }
        let pattern = text(column: startColumn, statement: statement)
        let sourcePath = sqlite3_column_type(statement, startColumn + 1) == SQLITE_NULL
            ? nil
            : text(column: startColumn + 1, statement: statement)
        let line = sqlite3_column_type(statement, startColumn + 2) == SQLITE_NULL
            ? nil
            : Int(sqlite3_column_int(statement, startColumn + 2))
        let builtIn = sqlite3_column_type(statement, startColumn + 3) == SQLITE_NULL
            ? nil
            : BuiltInExclusion(rawValue: text(column: startColumn + 3, statement: statement))
        return ExclusionReason(
            pattern: pattern,
            sourceURL: sourcePath.map(URL.init(fileURLWithPath:)),
            line: line,
            builtIn: builtIn
        )
    }

    static func addColumnIfMissing(
        _ column: String,
        definition: String,
        to table: String,
        database: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw IndexError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var exists = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 1),
               String(cString: value) == column {
                exists = true
                break
            }
        }
        guard !exists else { return }

        var error: UnsafeMutablePointer<CChar>?
        let sql = "ALTER TABLE \(table) ADD COLUMN \(column) \(definition)"
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw IndexError.sqlite(message)
        }
    }

    static func ftsUsesExternalContent(database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'documents_fts'",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else { return false }
        let normalized = String(cString: value)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        return normalized.contains("content='documents'")
            && normalized.contains("content_rowid='rowid'")
    }

    static func execute(_ sql: String, database: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw IndexError.sqlite(message)
        }
    }

    static func queryTerms(_ query: String) -> [String] {
        query
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
            .prefix(16)
            .map { String($0.prefix(128)) }
            .filter { !$0.isEmpty }
    }

    static func ftsQuery(_ terms: [String]) -> String? {
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " AND ")
    }

    static func escapedLike(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    static func firstMatchRange(in excerpt: String, terms: [String]) -> UTF16Range? {
        let source = excerpt as NSString
        let matches = terms.compactMap { term -> NSRange? in
            let range = source.range(
                of: term,
                options: [.caseInsensitive, .diacriticInsensitive]
            )
            return range.location == NSNotFound ? nil : range
        }
        guard let match = matches.min(by: { $0.location < $1.location }) else { return nil }
        return UTF16Range(location: match.location, length: match.length)
    }
}
