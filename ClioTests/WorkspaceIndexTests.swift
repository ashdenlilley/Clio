import Foundation
import XCTest
@testable import Clio

final class WorkspaceIndexTests: XCTestCase {
    func testGitIgnoreRulesCoverAnchoringNegationDirectoriesAndNestedBases() throws {
        let policy = DiscoveryPolicy(
            respectsGitIgnore: true,
            includesHiddenFiles: false,
            includesTextFiles: true,
            enabledBuiltIns: [],
            additionalPatterns: []
        )
        var matcher = GitIgnoreMatcher(policy: policy)
        let rootIgnore = URL(fileURLWithPath: "/workspace/.gitignore")
        matcher.appendGitIgnore(
            source: """
            # comment
            *.tmp
            /root-only.md
            generated/
            !generated/keep.md
            notes/**/scratch?.md
            """,
            sourceURL: rootIgnore,
            baseRelativePath: ""
        )
        let nestedIgnore = URL(fileURLWithPath: "/workspace/docs/.gitignore")
        matcher.appendGitIgnore(
            source: "draft.md\n!published-draft.md",
            sourceURL: nestedIgnore,
            baseRelativePath: "docs"
        )

        XCTAssertEqual(
            matcher.exclusionReason(for: "folder/cache.tmp", isDirectory: false)?.pattern,
            "*.tmp"
        )
        XCTAssertNotNil(matcher.exclusionReason(for: "root-only.md", isDirectory: false))
        XCTAssertNil(matcher.exclusionReason(for: "nested/root-only.md", isDirectory: false))
        XCTAssertNotNil(matcher.exclusionReason(for: "generated", isDirectory: true))
        XCTAssertNotNil(matcher.exclusionReason(for: "generated/other.md", isDirectory: false))
        XCTAssertNil(matcher.exclusionReason(for: "generated/keep.md", isDirectory: false))
        XCTAssertNotNil(matcher.exclusionReason(for: "notes/a/b/scratch1.md", isDirectory: false))
        XCTAssertNotNil(matcher.exclusionReason(for: "docs/draft.md", isDirectory: false))
        XCTAssertNil(matcher.exclusionReason(for: "docs/published-draft.md", isDirectory: false))
        XCTAssertNil(matcher.exclusionReason(for: "elsewhere/draft.md", isDirectory: false))
    }

    func testAppRulesOverrideGitIgnoreAndExplainBuiltIns() {
        let policy = DiscoveryPolicy(
            respectsGitIgnore: true,
            includesHiddenFiles: false,
            includesTextFiles: true,
            enabledBuiltIns: [.nodeModules],
            additionalPatterns: ["!node_modules/kept.md", "private/"]
        )
        var matcher = GitIgnoreMatcher(policy: policy)
        matcher.appendGitIgnore(
            source: "!private/visible.md",
            sourceURL: URL(fileURLWithPath: "/workspace/.gitignore"),
            baseRelativePath: ""
        )

        XCTAssertEqual(
            matcher.exclusionReason(for: "node_modules", isDirectory: true)?.builtIn,
            .nodeModules
        )
        XCTAssertNil(
            matcher.exclusionReason(for: "node_modules/kept.md", isDirectory: false)
        )
        XCTAssertEqual(
            matcher.exclusionReason(for: "private/visible.md", isDirectory: false)?.pattern,
            "private/"
        )
    }

    func testScannerPreservesIgnoredParentReasonAndNeverFollowsSymlinks() async throws {
        try await withTemporaryDirectory { rootURL in
            try write("ignored/\n*.tmp\n/root-only.md", to: rootURL.appendingPathComponent(".gitignore"))
            try write("visible", to: rootURL.appendingPathComponent("visible.md"))
            try write("root", to: rootURL.appendingPathComponent("root-only.md"))
            try write("temporary", to: rootURL.appendingPathComponent("cache.tmp"))
            try write("hidden", to: rootURL.appendingPathComponent(".hidden.md"))
            try write("text", to: rootURL.appendingPathComponent("notes.txt"))

            let ignoredURL = rootURL.appendingPathComponent("ignored", isDirectory: true)
            try FileManager.default.createDirectory(at: ignoredURL, withIntermediateDirectories: true)
            try write("!kept.md", to: ignoredURL.appendingPathComponent(".gitignore"))
            try write("still ignored", to: ignoredURL.appendingPathComponent("kept.md"))

            let outsideURL = rootURL.deletingLastPathComponent()
                .appendingPathComponent("ClioOutside-\(UUID().uuidString).md")
            try write("outside", to: outsideURL)
            defer { try? FileManager.default.removeItem(at: outsideURL) }
            try FileManager.default.createSymbolicLink(
                at: rootURL.appendingPathComponent("linked.md"),
                withDestinationURL: outsideURL
            )

            let workspace = WorkspaceDescriptor(rootURL: rootURL)
            let scanner = WorkspaceScanner()
            let normal = try await scanner.scan(
                workspace: workspace,
                policy: .default
            )
            XCTAssertEqual(Set(normal.files.map(\.relativePath)), ["visible.md", "notes.txt"])

            let showingIgnored = try await scanner.scan(
                workspace: workspace,
                policy: .default,
                includesIgnored: true
            )
            let files = Dictionary(uniqueKeysWithValues: showingIgnored.files.map { ($0.relativePath, $0) })
            XCTAssertNil(files["linked.md"])
            XCTAssertNil(files[".hidden.md"])
            XCTAssertEqual(files["root-only.md"]?.exclusionReason?.pattern, "/root-only.md")
            XCTAssertEqual(files["ignored/kept.md"]?.exclusionReason?.pattern, "ignored/")
        }
    }

    func testScannerSettingsControlTextHiddenAndBuiltInFiles() async throws {
        try await withTemporaryDirectory { rootURL in
            try write("markdown", to: rootURL.appendingPathComponent("note.md"))
            try write("text", to: rootURL.appendingPathComponent("note.txt"))
            try write("hidden", to: rootURL.appendingPathComponent(".note.md"))
            let modulesURL = rootURL.appendingPathComponent("node_modules", isDirectory: true)
            try FileManager.default.createDirectory(at: modulesURL, withIntermediateDirectories: true)
            try write("module", to: modulesURL.appendingPathComponent("readme.md"))

            var policy = DiscoveryPolicy.default
            policy.includesTextFiles = false
            policy.includesHiddenFiles = true
            policy.enabledBuiltIns.remove(.nodeModules)
            let snapshot = try await WorkspaceScanner().scan(
                workspace: WorkspaceDescriptor(rootURL: rootURL),
                policy: policy
            )
            XCTAssertEqual(
                Set(snapshot.files.map(\.relativePath)),
                ["note.md", ".note.md", "node_modules/readme.md"]
            )
        }
    }

    func testScannerMatchesGitIgnoreOracleForNestedAndEscapedRules() async throws {
        guard gitExecutableURL != nil else {
            throw XCTSkip("Git is unavailable for the differential ignore test.")
        }
        try await withTemporaryDirectory { rootURL in
            try runGit(["init", "--quiet"], at: rootURL)
            try write(
                """
                *.tmp.md
                /root-only.md
                blocked/
                !blocked/keep.md
                build/
                !build/
                build/*
                !build/keep.md
                a/**/deep.md
                a**b.md
                range[0-3].md
                \\#literal.md
                \\!literal.md
                escaped\\ space.md
                invalid\\
                """,
                to: rootURL.appendingPathComponent(".gitignore")
            )
            try write("*.md\r\n!keep.md\r\n", to: rootURL.appendingPathComponent("docs/.gitignore"))
            let paths = [
                "cache.tmp.md",
                "root-only.md",
                "nested/root-only.md",
                "blocked/keep.md",
                "build/drop.md",
                "build/keep.md",
                "a/deep.md",
                "a/x/y/deep.md",
                "a/x/b.md",
                "acb.md",
                "range2.md",
                "range8.md",
                "#literal.md",
                "!literal.md",
                "escaped space.md",
                "invalid",
                "docs/drop.md",
                "docs/keep.md",
            ]
            for path in paths {
                try write(path, to: rootURL.appendingPathComponent(path))
            }

            let policy = DiscoveryPolicy(
                respectsGitIgnore: true,
                includesHiddenFiles: true,
                includesTextFiles: true,
                enabledBuiltIns: [],
                additionalPatterns: []
            )
            let snapshot = try await WorkspaceScanner().scan(
                workspace: WorkspaceDescriptor(rootURL: rootURL),
                policy: policy,
                includesIgnored: true
            )
            let reasons = Dictionary(
                uniqueKeysWithValues: snapshot.files.map { ($0.relativePath, $0.exclusionReason) }
            )
            for path in paths where URL(fileURLWithPath: path).pathExtension.lowercased() == "md" {
                XCTAssertEqual(
                    reasons[path].flatMap { $0 } != nil,
                    try gitReportsIgnored(path, at: rootURL),
                    "Git-ignore mismatch for \(path)"
                )
            }
            XCTAssertEqual(reasons["docs/drop.md"].flatMap { $0 }?.line, 1)
            XCTAssertNil(reasons["docs/keep.md"] ?? nil)
        }
    }

    func testSQLiteIndexSearchFilteringInvalidationAndStableIdentity() async throws {
        try await withTemporaryDirectory { rootURL in
            try write("ignored.md", to: rootURL.appendingPathComponent(".gitignore"))
            let alphaURL = rootURL.appendingPathComponent("alpha.md")
            try write("A quiet searchable phrase.\nSecond line.", to: alphaURL)
            try write("Hidden searchable phrase.", to: rootURL.appendingPathComponent("ignored.md"))

            let databaseURL = rootURL.appendingPathComponent("index.sqlite3")
            let workspace = WorkspaceDescriptor(rootURL: rootURL)
            let index = try SQLiteSearchIndex(databaseURL: databaseURL)
            try await index.rebuild(workspaces: [workspace], policy: .default)

            let quick = try await finalBatch(
                from: await index.quickOpen(WorkspaceSearchQuery(text: "alp"))
            )
            let firstID = try XCTUnwrap(quick.results.first?.documentID)
            XCTAssertEqual(quick.results.first?.relativePath, "alpha.md")

            let search = try await finalBatch(
                from: await index.search(WorkspaceSearchQuery(text: "searchable phrase"))
            )
            XCTAssertEqual(search.results.map(\.relativePath), ["alpha.md"])
            XCTAssertNotNil(search.results.first?.excerptMatchRange)

            let ignored = try await finalBatch(
                from: await index.search(
                    WorkspaceSearchQuery(text: "Hidden", includesIgnored: true)
                )
            )
            XCTAssertEqual(ignored.results.first?.relativePath, "ignored.md")
            XCTAssertEqual(ignored.results.first?.exclusionReason?.pattern, "ignored.md")

            try await index.rebuild(workspaces: [workspace], policy: .default)
            let rebuilt = try await finalBatch(
                from: await index.quickOpen(WorkspaceSearchQuery(text: "alpha"))
            )
            XCTAssertEqual(rebuilt.results.first?.documentID, firstID)

            try write("A replacement token.", to: alphaURL)
            try await index.apply([
                WorkspaceEvent(
                    workspaceID: workspace.id,
                    kind: .modified,
                    fileURL: alphaURL,
                    origin: .external
                ),
            ])
            let updated = try await finalBatch(
                from: await index.search(WorkspaceSearchQuery(text: "replacement"))
            )
            XCTAssertEqual(updated.results.first?.documentID, firstID)

            let movedURL = rootURL.appendingPathComponent("renamed.md")
            try FileManager.default.moveItem(at: alphaURL, to: movedURL)
            try await index.apply([
                WorkspaceEvent(
                    workspaceID: workspace.id,
                    kind: .moved,
                    fileURL: movedURL,
                    previousFileURL: alphaURL,
                    origin: .external
                ),
            ])
            let moved = try await finalBatch(
                from: await index.quickOpen(WorkspaceSearchQuery(text: "renamed"))
            )
            XCTAssertEqual(moved.results.first?.documentID, firstID)

            try FileManager.default.removeItem(at: movedURL)
            try await index.apply([
                WorkspaceEvent(
                    workspaceID: workspace.id,
                    kind: .deleted,
                    fileURL: movedURL,
                    origin: .external
                ),
            ])
            let deleted = try await finalBatch(
                from: await index.quickOpen(WorkspaceSearchQuery(text: "renamed"))
            )
            XCTAssertTrue(deleted.results.isEmpty)
        }
    }

    func testIncrementalIndexTreatsDisappearingModifiedFileAsDeletion() async throws {
        try await withTemporaryDirectory { rootURL in
            let documentURL = rootURL.appendingPathComponent("ephemeral.md")
            try write("short lived token", to: documentURL)
            let workspace = WorkspaceDescriptor(rootURL: rootURL)
            let index = try SQLiteSearchIndex(
                databaseURL: rootURL.appendingPathComponent("index.sqlite3")
            )
            try await index.rebuild(workspaces: [workspace], policy: .default)
            try FileManager.default.removeItem(at: documentURL)

            try await index.apply([
                WorkspaceEvent(
                    workspaceID: workspace.id,
                    kind: .modified,
                    fileURL: documentURL,
                    origin: .external
                ),
            ])

            let results = try await finalBatch(
                from: await index.search(WorkspaceSearchQuery(text: "short lived"))
            )
            XCTAssertTrue(results.results.isEmpty)
        }
    }

    func testSQLiteIndexDeduplicatesOverlappingWorkspaceRoots() async throws {
        try await withTemporaryDirectory { rootURL in
            let nestedURL = rootURL.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
            try write("one unique needle", to: nestedURL.appendingPathComponent("note.md"))

            let index = try SQLiteSearchIndex(
                databaseURL: rootURL.appendingPathComponent("overlap.sqlite3")
            )
            let root = WorkspaceDescriptor(rootURL: rootURL)
            let nested = WorkspaceDescriptor(rootURL: nestedURL)
            try await index.rebuild(
                workspaces: [root, nested],
                policy: .default
            )
            let batch = try await finalBatch(
                from: await index.search(WorkspaceSearchQuery(text: "needle"))
            )
            XCTAssertEqual(batch.results.count, 1)
            XCTAssertEqual(batch.results.first?.workspaceID, nested.id)
            XCTAssertEqual(batch.results.first?.relativePath, "note.md")

            let parentFilter = try await finalBatch(
                from: await index.search(
                    WorkspaceSearchQuery(text: "needle", workspaceFilter: root.id)
                )
            )
            XCTAssertEqual(parentFilter.results.first?.relativePath, "nested/note.md")
        }
    }

    func testContentSearchReturnsBoundedExcerptForTenMiBSingleLine() async throws {
        try await withTemporaryDirectory { rootURL in
            let half = PerformanceContract.fullMarkdownByteLimit / 2
            let source = String(repeating: "a", count: half)
                + " needle "
                + String(repeating: "z", count: half - 8)
            try write(source, to: rootURL.appendingPathComponent("large.md"))
            let index = try SQLiteSearchIndex(
                databaseURL: rootURL.appendingPathComponent("large-index.sqlite3")
            )
            try await index.rebuild(
                workspaces: [WorkspaceDescriptor(rootURL: rootURL)],
                policy: .default
            )
            let batch = try await finalBatch(
                from: await index.search(WorkspaceSearchQuery(text: "needle"))
            )
            let result = try XCTUnwrap(batch.results.first)
            XCTAssertLessThanOrEqual(result.excerpt?.count ?? .max, 1_024)
            XCTAssertNotNil(result.excerptMatchRange)
        }
    }

    func testSearchEscapesOperatorsAndSurvivesImmediateCancellation() async throws {
        try await withTemporaryDirectory { rootURL in
            try write(
                "Compass 🧭 café cafe\u{301} quote OR AND percent underscore slash.",
                to: rootURL.appendingPathComponent("100%_notes.md")
            )
            let index = try SQLiteSearchIndex(
                databaseURL: rootURL.appendingPathComponent("queries.sqlite3")
            )
            try await index.rebuild(
                workspaces: [WorkspaceDescriptor(rootURL: rootURL)],
                policy: .default
            )

            let escapedPath = try await finalBatch(
                from: await index.quickOpen(WorkspaceSearchQuery(text: "%_"))
            )
            XCTAssertEqual(escapedPath.results.first?.relativePath, "100%_notes.md")

            let operators = try await finalBatch(
                from: await index.search(WorkspaceSearchQuery(text: "\"café\" OR AND"))
            )
            XCTAssertEqual(operators.results.first?.relativePath, "100%_notes.md")

            let stream = await index.search(
                WorkspaceSearchQuery(text: String(repeating: "needle ", count: 2_000))
            )
            let cancelled = Task {
                for try await _ in stream {}
            }
            cancelled.cancel()
            _ = try? await cancelled.value

            let subsequent = try await finalBatch(
                from: await index.search(WorkspaceSearchQuery(text: "Compass"))
            )
            XCTAssertEqual(subsequent.results.first?.relativePath, "100%_notes.md")
        }
    }

    func testConcurrentRebuildKeepsPreviousIndexQueryable() async throws {
        try await withTemporaryDirectory { rootURL in
            try write("stable previous content", to: rootURL.appendingPathComponent("stable.md"))
            let workspace = WorkspaceDescriptor(rootURL: rootURL)
            let index = try SQLiteSearchIndex(
                databaseURL: rootURL.appendingPathComponent("concurrent.sqlite3")
            )
            try await index.rebuild(workspaces: [workspace], policy: .default)
            for number in 0..<500 {
                try write(
                    "background rebuild \(number)",
                    to: rootURL.appendingPathComponent("bulk/\(number).md")
                )
            }

            let rebuilding = Task {
                try await index.rebuild(workspaces: [workspace], policy: .default)
            }
            await Task.yield()
            let duringRebuild = try await finalBatch(
                from: await index.search(WorkspaceSearchQuery(text: "stable previous"))
            )
            XCTAssertEqual(duringRebuild.results.first?.relativePath, "stable.md")
            try await rebuilding.value

            let afterRebuild = try await finalBatch(
                from: await index.search(WorkspaceSearchQuery(text: "background 499"))
            )
            XCTAssertEqual(afterRebuild.results.first?.relativePath, "bulk/499.md")
        }
    }

    @MainActor
    func testDiscoverySettingsPersistEveryWorkspaceRule() throws {
        let suiteName = "ClioWorkspaceIndexTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = WorkspaceDiscoverySettings(defaults: defaults)
        settings.respectsGitIgnore = false
        settings.includesHiddenFiles = true
        settings.includesTextFiles = false
        settings.set(.caches, enabled: false)
        settings.additionalPatternsText = "private/\n*.secret"

        let restored = WorkspaceDiscoverySettings(defaults: defaults)
        XCTAssertFalse(restored.policy.respectsGitIgnore)
        XCTAssertTrue(restored.policy.includesHiddenFiles)
        XCTAssertFalse(restored.policy.includesTextFiles)
        XCTAssertFalse(restored.policy.enabledBuiltIns.contains(.caches))
        XCTAssertEqual(restored.policy.additionalPatterns, ["private/", "*.secret"])
    }

    @MainActor
    func testWorkspaceCatalogRestoresGlobalBookmarksAndStableIDs() async throws {
        try await withTemporaryDirectory { rootURL in
            let suiteName = "ClioWorkspaceCatalogTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let makeBookmark: (URL) throws -> Data = { Data($0.path.utf8) }
            let resolveBookmark: (Data) throws -> Workspace.BookmarkResolution = { data in
                Workspace.BookmarkResolution(
                    url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)),
                    isStale: false
                )
            }
            let makeWorkspace: (URL) throws -> Workspace = {
                try Workspace(rootURL: $0, accessSecurityScopedResource: false)
            }

            let first = WorkspaceCatalog(
                defaults: defaults,
                bookmarkMaker: makeBookmark,
                bookmarkResolver: resolveBookmark,
                workspaceFactory: makeWorkspace
            )
            let added = try first.addAuthorizedFolder(rootURL)
            XCTAssertEqual(first.descriptor(containing: rootURL.appendingPathComponent("draft.md"))?.id, added.id)

            let nestedURL = rootURL.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
            let nested = try first.addAuthorizedFolder(nestedURL)
            XCTAssertEqual(
                first.descriptor(containing: nestedURL.appendingPathComponent("draft.md"))?.id,
                nested.id
            )

            let restored = WorkspaceCatalog(
                defaults: defaults,
                bookmarkMaker: makeBookmark,
                bookmarkResolver: resolveBookmark,
                workspaceFactory: makeWorkspace
            )
            XCTAssertEqual(Set(restored.descriptors.map(\.id)), [added.id, nested.id])
            XCTAssertEqual(
                restored.descriptor(containing: nestedURL.appendingPathComponent("draft.md"))?.id,
                nested.id
            )

            restored.remove(added.id)
            restored.remove(nested.id)
            XCTAssertTrue(restored.descriptors.isEmpty)
            let empty = WorkspaceCatalog(
                defaults: defaults,
                bookmarkMaker: makeBookmark,
                bookmarkResolver: resolveBookmark,
                workspaceFactory: makeWorkspace
            )
            XCTAssertTrue(empty.descriptors.isEmpty)
        }
    }

    @MainActor
    func testWorkspaceCatalogRetainsFailedGrantUntilReauthorization() async throws {
        try await withTemporaryDirectory { rootURL in
            let suiteName = "ClioWorkspaceGrantTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let makeBookmark: @MainActor (URL) throws -> Data = { Data($0.path.utf8) }
            let resolve: @MainActor (Data) throws -> Workspace.BookmarkResolution = { data in
                Workspace.BookmarkResolution(
                    url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)),
                    isStale: false
                )
            }
            let makeWorkspace: @MainActor (URL) throws -> Workspace = {
                try Workspace(rootURL: $0, accessSecurityScopedResource: false)
            }
            let initial = WorkspaceCatalog(
                defaults: defaults,
                bookmarkMaker: makeBookmark,
                bookmarkResolver: resolve,
                workspaceFactory: makeWorkspace
            )
            let descriptor = try initial.addAuthorizedFolder(rootURL)

            var canResolve = false
            let conditionalResolve: @MainActor (Data) throws -> Workspace.BookmarkResolution = { data in
                guard canResolve else { throw CocoaError(.fileReadNoPermission) }
                return try resolve(data)
            }
            let unavailable = WorkspaceCatalog(
                defaults: defaults,
                bookmarkMaker: makeBookmark,
                bookmarkResolver: conditionalResolve,
                workspaceFactory: makeWorkspace
            )
            XCTAssertEqual(unavailable.authorizationFailures.first?.id, descriptor.id)
            XCTAssertTrue(unavailable.descriptors.isEmpty)

            canResolve = true
            try unavailable.reauthorize(descriptor.id, with: rootURL)
            XCTAssertEqual(unavailable.descriptors.first?.id, descriptor.id)
            let restored = WorkspaceCatalog(
                defaults: defaults,
                bookmarkMaker: makeBookmark,
                bookmarkResolver: resolve,
                workspaceFactory: makeWorkspace
            )
            XCTAssertEqual(restored.descriptors.first?.id, descriptor.id)
        }
    }
}

private extension WorkspaceIndexTests {
    var gitExecutableURL: URL? {
        [
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git",
        ]
        .first(where: FileManager.default.isExecutableFile(atPath:))
        .map(URL.init(fileURLWithPath:))
    }

    func write(_ source: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(source.utf8).write(to: url, options: .atomic)
    }

    func runGit(_ arguments: [String], at rootURL: URL) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = try XCTUnwrap(gitExecutableURL)
        process.arguments = ["-C", rootURL.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "ClioTests.Git",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "git \(arguments.joined(separator: " ")) failed: \(detail)",
                ]
            )
        }
    }

    func gitReportsIgnored(_ path: String, at rootURL: URL) throws -> Bool {
        let process = Process()
        process.executableURL = try XCTUnwrap(gitExecutableURL)
        process.arguments = ["-C", rootURL.path, "check-ignore", "--no-index", "--quiet", "--", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        switch process.terminationStatus {
        case 0: return true
        case 1: return false
        default:
            throw NSError(
                domain: "ClioTests.Git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git check-ignore failed for \(path)"]
            )
        }
    }

    func finalBatch(
        from stream: AsyncThrowingStream<SearchBatch, Error>
    ) async throws -> SearchBatch {
        var final = SearchBatch(results: [], isFinal: true)
        for try await batch in stream {
            final = batch
        }
        return final
    }

    func withTemporaryDirectory<T>(
        _ operation: (URL) async throws -> T
    ) async throws -> T {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioWorkspaceIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        return try await operation(directoryURL)
    }
}
