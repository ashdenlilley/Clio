import Foundation
import XCTest
@testable import Clio

@MainActor
final class DataSafetyTests: XCTestCase {
    func testRegistryReturnsOneCanonicalBufferForEquivalentReferences() throws {
        try withDirectories { workspaceURL, _ in
            let fileURL = workspaceURL.appendingPathComponent("draft.md")
            try Data("one".utf8).write(to: fileURL)
            let workspace = try Workspace(
                rootURL: workspaceURL,
                accessSecurityScopedResource: false
            )
            let registry = DocumentBufferRegistry()

            let first = try registry.open(fileURL, in: workspace)
            let second = try registry.open(
                workspaceURL.appendingPathComponent("./draft.md"),
                in: workspace
            )

            XCTAssertTrue(first === second)
            XCTAssertEqual(first.id, second.id)
        }
    }

    func testTwoSessionsEditTheSameCanonicalBuffer() throws {
        try withDirectories { workspaceURL, recoveryURL in
            let fileURL = workspaceURL.appendingPathComponent("draft.md")
            try Data("before".utf8).write(to: fileURL)
            let workspace = try Workspace(
                rootURL: workspaceURL,
                accessSecurityScopedResource: false
            )
            let registry = DocumentBufferRegistry()
            let recovery = RecoveryStore(rootURL: recoveryURL)
            let resolver = ConflictResolver(recoveryStore: recovery)
            let mover = DocumentMover(recoveryStore: recovery)
            let first = EditorSession()
            let second = EditorSession()

            first.activate(
                in: workspace,
                documentURLs: [fileURL],
                registry: registry,
                conflictResolver: resolver,
                documentMover: mover
            )
            second.activate(
                in: workspace,
                documentURLs: [fileURL],
                registry: registry,
                conflictResolver: resolver,
                documentMover: mover
            )
            first.editorTextDidChange("shared")

            XCTAssertTrue(first.document === second.document)
            XCTAssertEqual(second.draftText, "shared")
        }
    }

    func testTwoSessionsShareOneAutosavePipelineAndCannotRaceExternalEdit() async throws {
        try await withDirectories { workspaceURL, recoveryURL in
            let fileURL = workspaceURL.appendingPathComponent("draft.md")
            try Data("base".utf8).write(to: fileURL)
            let workspace = try Workspace(rootURL: workspaceURL, accessSecurityScopedResource: false)
            let registry = DocumentBufferRegistry()
            let recovery = RecoveryStore(rootURL: recoveryURL)
            let resolver = ConflictResolver(recoveryStore: recovery)
            let mover = DocumentMover(recoveryStore: recovery)
            let first = EditorSession()
            let second = EditorSession()
            for session in [first, second] {
                session.activate(
                    in: workspace,
                    documentURLs: [fileURL],
                    registry: registry,
                    conflictResolver: resolver,
                    documentMover: mover
                )
            }
            let document = try XCTUnwrap(first.document)
            XCTAssertTrue(
                registry.autosaver(for: document, in: workspace)
                    === registry.autosaver(for: document, in: workspace)
            )

            first.editorTextDidChange("first local")
            second.editorTextDidChange("latest local")
            try Data("outside".utf8).write(to: fileURL, options: .atomic)
            try await Task.sleep(for: .milliseconds(500))

            XCTAssertEqual(first.draftText, "latest local")
            XCTAssertEqual(second.draftText, "latest local")
            XCTAssertNotNil(first.activeConflict)
            XCTAssertEqual(try String(contentsOf: fileURL), "outside")
        }
    }

    func testRestoredDuplicatePathUsesCanonicalBufferEvenWhenAlreadyOpen() throws {
        try withDirectories { workspaceURL, recoveryURL in
            let fileURL = workspaceURL.appendingPathComponent("draft.md")
            try Data("shared".utf8).write(to: fileURL)
            let workspace = try Workspace(rootURL: workspaceURL, accessSecurityScopedResource: false)
            let state = AppState(
                defaults: UserDefaults(suiteName: "ClioTests.\(UUID().uuidString)")!,
                initialWorkspace: workspace,
                recoveryStore: RecoveryStore(rootURL: recoveryURL)
            )
            let first = EditorSession(openingMode: .mostRecent)
            let restored = EditorSession(
                openingMode: .newDocument,
                restoredRelativePath: "draft.md"
            )

            state.register(first)
            state.register(restored)

            XCTAssertTrue(first.document === restored.document)
            first.editorTextDidChange("from first")
            XCTAssertEqual(restored.draftText, "from first")
        }
    }

    func testAppWatcherReloadsCleanBufferAndRetainsItAfterDeletion() async throws {
        try await withDirectories { workspaceURL, recoveryURL in
            let fileURL = workspaceURL.appendingPathComponent("draft.md")
            try Data("base".utf8).write(to: fileURL)
            let workspace = try Workspace(rootURL: workspaceURL, accessSecurityScopedResource: false)
            let state = AppState(
                defaults: UserDefaults(suiteName: "ClioTests.\(UUID().uuidString)")!,
                initialWorkspace: workspace,
                recoveryStore: RecoveryStore(rootURL: recoveryURL)
            )
            let session = EditorSession()
            state.register(session)
            try await Task.sleep(for: .milliseconds(120))

            try Data("outside".utf8).write(to: fileURL, options: .atomic)
            try await waitUntil { session.draftText == "outside" }
            try FileManager.default.removeItem(at: fileURL)
            try await waitUntil { session.fileURL == nil }

            XCTAssertEqual(session.draftText, "outside")
            XCTAssertTrue(session.document?.isDirty == true)
        }
    }

    func testAppWatcherTurnsDirtyOutsideEditIntoConflict() async throws {
        try await withDirectories { workspaceURL, recoveryURL in
            let fileURL = workspaceURL.appendingPathComponent("draft.md")
            try Data("base".utf8).write(to: fileURL)
            let workspace = try Workspace(rootURL: workspaceURL, accessSecurityScopedResource: false)
            let state = AppState(
                defaults: UserDefaults(suiteName: "ClioTests.\(UUID().uuidString)")!,
                initialWorkspace: workspace,
                recoveryStore: RecoveryStore(rootURL: recoveryURL)
            )
            let session = EditorSession()
            state.register(session)
            try await Task.sleep(for: .milliseconds(120))

            session.editorTextDidChange("clio")
            try Data("outside".utf8).write(to: fileURL, options: .atomic)
            try await waitUntil { session.activeConflict != nil }

            XCTAssertEqual(session.draftText, "clio")
            XCTAssertEqual(try String(contentsOf: fileURL), "outside")
        }
    }

    func testAppWatcherDoesNotReclassifyClioSaveAsExternal() async throws {
        try await withDirectories { workspaceURL, recoveryURL in
            let fileURL = workspaceURL.appendingPathComponent("draft.md")
            try Data("base".utf8).write(to: fileURL)
            let workspace = try Workspace(rootURL: workspaceURL, accessSecurityScopedResource: false)
            let state = AppState(
                defaults: UserDefaults(suiteName: "ClioTests.\(UUID().uuidString)")!,
                initialWorkspace: workspace,
                recoveryStore: RecoveryStore(rootURL: recoveryURL)
            )
            let session = EditorSession()
            state.register(session)
            try await Task.sleep(for: .milliseconds(120))

            session.editorTextDidChange("saved by Clio")
            session.saveNow()
            try await Task.sleep(for: .milliseconds(200))

            XCTAssertNil(session.activeConflict)
            XCTAssertEqual(session.draftText, "saved by Clio")
            XCTAssertEqual(try String(contentsOf: fileURL), "saved by Clio")
        }
    }

    func testConcurrentOutsideEditPausesSaveWithoutOverwrite() throws {
        try withDirectories { workspaceURL, _ in
            let fileURL = workspaceURL.appendingPathComponent("draft.md")
            try Data("base".utf8).write(to: fileURL)
            let workspace = try Workspace(
                rootURL: workspaceURL,
                accessSecurityScopedResource: false
            )
            let document = try workspace.loadDocument(at: fileURL)
            document.replaceText(with: "clio")
            try Data("outside".utf8).write(to: fileURL, options: .atomic)

            XCTAssertThrowsError(try workspace.save(document)) { error in
                guard case Workspace.WorkspaceError.externalConflict = error else {
                    return XCTFail("Expected external conflict, got \(error)")
                }
            }
            XCTAssertEqual(try String(contentsOf: fileURL), "outside")
            XCTAssertEqual(document.text, "clio")
            XCTAssertTrue(document.isAutosavePaused)
            XCTAssertTrue(document.conflict?.conciseDiff.contains("clio") == true)
        }
    }

    func testCleanOutsideEditReloadsInPlace() throws {
        try withDirectories { workspaceURL, _ in
            let fileURL = workspaceURL.appendingPathComponent("draft.md")
            try Data("base".utf8).write(to: fileURL)
            let workspace = try Workspace(
                rootURL: workspaceURL,
                accessSecurityScopedResource: false
            )
            let document = try workspace.loadDocument(at: fileURL)
            try Data("outside".utf8).write(to: fileURL, options: .atomic)

            try workspace.reconcileExternalChange(for: document)

            XCTAssertEqual(document.text, "outside")
            XCTAssertFalse(document.isDirty)
            XCTAssertNil(document.conflict)
        }
    }

    func testSelfWriteEventIsSuppressed() throws {
        try withDirectories { workspaceURL, _ in
            let fileURL = workspaceURL.appendingPathComponent("draft.md")
            try Data("base".utf8).write(to: fileURL)
            let workspace = try Workspace(
                rootURL: workspaceURL,
                accessSecurityScopedResource: false
            )
            let document = try workspace.loadDocument(at: fileURL)
            document.replaceText(with: "clio")
            try workspace.save(document)

            try workspace.reconcileExternalChange(for: document)

            XCTAssertEqual(document.text, "clio")
            XCTAssertFalse(document.isDirty)
            XCTAssertNil(document.conflict)
        }
    }

    func testAtomicFailureLeavesOriginalAndDirtyBuffer() throws {
        try withDirectories { workspaceURL, _ in
            let fileURL = workspaceURL.appendingPathComponent("draft.md")
            try Data("base".utf8).write(to: fileURL)
            let workspace = try Workspace(
                rootURL: workspaceURL,
                accessSecurityScopedResource: false,
                atomicWriter: FailingAtomicWriter()
            )
            let document = try workspace.loadDocument(at: fileURL)
            document.replaceText(with: "unsaved")

            XCTAssertThrowsError(try workspace.save(document))
            XCTAssertEqual(try String(contentsOf: fileURL), "base")
            XCTAssertEqual(document.text, "unsaved")
            XCTAssertTrue(document.isDirty)
        }
    }

    func testAtomicSwapRestoresOutsideEditThatLandsBeforeCommit() throws {
        try withDirectories { workspaceURL, _ in
            let fileURL = workspaceURL.appendingPathComponent("draft.md")
            try Data("base".utf8).write(to: fileURL)
            let expected = try DocumentRevisionReader.revision(at: fileURL)
            var writer = AtomicFileWriter()
            writer.beforeSwap = {
                try Data("outside".utf8).write(to: fileURL, options: .atomic)
            }

            let outcome = try writer.replace(
                contents: Data("clio".utf8),
                at: fileURL,
                onlyIf: expected
            )

            XCTAssertEqual(outcome, .revisionMismatch(retainedURL: nil))
            XCTAssertEqual(try String(contentsOf: fileURL), "outside")
        }
    }

    func testAtomicSwapRetainsEveryOutsideRevisionAcrossDoubleInterleaving() throws {
        try withDirectories { workspaceURL, _ in
            let fileURL = workspaceURL.appendingPathComponent("draft.md")
            try Data("base".utf8).write(to: fileURL)
            let expected = try DocumentRevisionReader.revision(at: fileURL)
            var writer = AtomicFileWriter()
            writer.beforeSwap = {
                try Data("outside before".utf8).write(to: fileURL, options: .atomic)
            }
            writer.afterSwap = {
                try Data("outside after".utf8).write(to: fileURL, options: .atomic)
            }

            let outcome = try writer.replace(
                contents: Data("clio".utf8),
                at: fileURL,
                onlyIf: expected
            )
            guard case .revisionMismatch(let retainedURL?) = outcome else {
                return XCTFail("Expected the displaced outside revision to be retained")
            }

            XCTAssertEqual(try String(contentsOf: fileURL), "outside after")
            XCTAssertEqual(try String(contentsOf: retainedURL), "outside before")
        }
    }

    func testLoadExternalPreservesLocalRecoveryFirst() async throws {
        try await withDirectories { workspaceURL, recoveryURL in
            let setup = try makeConflict(workspaceURL: workspaceURL)
            let resolver = ConflictResolver(
                recoveryStore: RecoveryStore(rootURL: recoveryURL)
            )

            let receipt = try await resolver.resolve(
                .loadExternal,
                document: setup.document,
                workspace: setup.workspace
            )

            XCTAssertEqual(setup.document.text, "outside")
            XCTAssertEqual(
                try String(contentsOf: XCTUnwrap(receipt?.recoveryURL)),
                "clio"
            )
        }
    }

    func testKeepClioPreservesExternalRecoveryFirst() async throws {
        try await withDirectories { workspaceURL, recoveryURL in
            let setup = try makeConflict(workspaceURL: workspaceURL)
            let resolver = ConflictResolver(
                recoveryStore: RecoveryStore(rootURL: recoveryURL)
            )

            let receipt = try await resolver.resolve(
                .keepClio,
                document: setup.document,
                workspace: setup.workspace
            )

            XCTAssertEqual(try String(contentsOf: setup.fileURL), "clio")
            XCTAssertEqual(
                try String(contentsOf: XCTUnwrap(receipt?.recoveryURL)),
                "outside"
            )
            XCTAssertFalse(setup.document.isDirty)
        }
    }

    func testFailedRecoveryPreventsConflictReplacement() async throws {
        try await withDirectories { workspaceURL, recoveryURL in
            let setup = try makeConflict(workspaceURL: workspaceURL)
            try Data("not a directory".utf8).write(to: recoveryURL)
            let resolver = ConflictResolver(
                recoveryStore: RecoveryStore(rootURL: recoveryURL)
            )

            do {
                _ = try await resolver.resolve(
                    .keepClio,
                    document: setup.document,
                    workspace: setup.workspace
                )
                XCTFail("Expected recovery failure")
            } catch {
                XCTAssertEqual(try String(contentsOf: setup.fileURL), "outside")
                XCTAssertEqual(setup.document.text, "clio")
                XCTAssertNotNil(setup.document.conflict)
            }
        }
    }

    func testKeepBothLeavesExternalAndCreatesNumberedClioCopy() async throws {
        try await withDirectories { workspaceURL, recoveryURL in
            let setup = try makeConflict(workspaceURL: workspaceURL)
            let resolver = ConflictResolver(
                recoveryStore: RecoveryStore(rootURL: recoveryURL)
            )

            _ = try await resolver.resolve(
                .keepBoth,
                document: setup.document,
                workspace: setup.workspace
            )

            XCTAssertEqual(try String(contentsOf: setup.fileURL), "outside")
            XCTAssertEqual(setup.document.filename, "draft (2).md")
            XCTAssertEqual(
                try String(contentsOf: XCTUnwrap(setup.document.fileURL)),
                "clio"
            )
        }
    }

    func testDeletionLeavesBufferOpenAndUnbacked() throws {
        try withDirectories { workspaceURL, _ in
            let fileURL = workspaceURL.appendingPathComponent("draft.md")
            try Data("recoverable".utf8).write(to: fileURL)
            let workspace = try Workspace(
                rootURL: workspaceURL,
                accessSecurityScopedResource: false
            )
            let document = try workspace.loadDocument(at: fileURL)
            try FileManager.default.removeItem(at: fileURL)

            try workspace.reconcileExternalChange(for: document)
            try Data("replacement".utf8).write(to: fileURL)

            XCTAssertNil(document.fileURL)
            XCTAssertEqual(document.text, "recoverable")
            XCTAssertTrue(document.isDirty)
            XCTAssertEqual(try String(contentsOf: fileURL), "replacement")
        }
    }

    func testConflictRefreshesWhenExternalChangesAgain() async throws {
        try await withDirectories { workspaceURL, recoveryURL in
            let setup = try makeConflict(workspaceURL: workspaceURL)
            try Data("outside again".utf8).write(to: setup.fileURL, options: .atomic)
            let resolver = ConflictResolver(
                recoveryStore: RecoveryStore(rootURL: recoveryURL)
            )

            do {
                _ = try await resolver.resolve(
                    .keepClio,
                    document: setup.document,
                    workspace: setup.workspace
                )
                XCTFail("Expected the second outside edit to require review")
            } catch ConflictResolver.ResolutionError.conflictChanged {
                XCTAssertEqual(try String(contentsOf: setup.fileURL), "outside again")
                XCTAssertEqual(setup.document.text, "clio")
                XCTAssertEqual(setup.document.conflict?.external.source, "outside again")
            }
        }
    }

    func testMoveCollisionCanCancelOrKeepBoth() async throws {
        try await withDirectories { sourceURL, recoveryURL in
            let destinationURL = sourceURL.appendingPathComponent("destination", isDirectory: true)
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            let sourceFile = sourceURL.appendingPathComponent("draft.md")
            let occupied = destinationURL.appendingPathComponent("draft.md")
            try Data("moving".utf8).write(to: sourceFile)
            try Data("occupied".utf8).write(to: occupied)
            let source = try Workspace(rootURL: sourceURL, accessSecurityScopedResource: false)
            let destination = try Workspace(rootURL: destinationURL, accessSecurityScopedResource: false)
            let document = try source.loadDocument(at: sourceFile)
            let mover = DocumentMover(
                recoveryStore: RecoveryStore(rootURL: recoveryURL)
            )

            let proposed = try await mover.move(
                document,
                from: source,
                to: destination
            )
            guard case .collision = proposed else { return XCTFail("Expected collision") }
            let cancelled = try await mover.move(
                document,
                from: source,
                to: destination,
                collisionChoice: .cancel
            )
            XCTAssertEqual(cancelled, .cancelled)
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFile.path))

            let kept = try await mover.move(
                document,
                from: source,
                to: destination,
                collisionChoice: .keepBoth
            )
            guard case .completed(let locator) = kept else { return XCTFail("Expected move") }
            XCTAssertEqual(locator.relativePath, "draft (2).md")
            XCTAssertEqual(try String(contentsOf: occupied), "occupied")
            XCTAssertEqual(try String(contentsOf: XCTUnwrap(document.fileURL)), "moving")
        }
    }

    func testReplaceMoveCreatesRecoveryAndPreservesCanonicalBuffer() async throws {
        try await withDirectories { sourceURL, recoveryURL in
            let destinationURL = sourceURL.appendingPathComponent("destination", isDirectory: true)
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            let sourceFile = sourceURL.appendingPathComponent("draft.md")
            let occupied = destinationURL.appendingPathComponent("draft.md")
            try Data("moving".utf8).write(to: sourceFile)
            try Data("occupied".utf8).write(to: occupied)
            let source = try Workspace(rootURL: sourceURL, accessSecurityScopedResource: false)
            let destination = try Workspace(rootURL: destinationURL, accessSecurityScopedResource: false)
            let document = try source.loadDocument(at: sourceFile)
            let registry = DocumentBufferRegistry()
            registry.register(document, in: source)
            let mover = DocumentMover(
                recoveryStore: RecoveryStore(rootURL: recoveryURL)
            )

            let proposal = try await mover.move(
                document,
                from: source,
                to: destination,
                registry: registry
            )
            guard case .collision(let approvedCollision) = proposal else {
                return XCTFail("Expected collision approval")
            }
            _ = try await mover.move(
                document,
                from: source,
                to: destination,
                collisionChoice: .replace,
                approvedCollision: approvedCollision,
                registry: registry
            )

            XCTAssertEqual(document.fileURL, occupied)
            XCTAssertTrue(registry.document(at: occupied, in: destination) === document)
            XCTAssertEqual(try String(contentsOf: occupied), "moving")
            let recoveries = try FileManager.default.contentsOfDirectory(
                at: recoveryURL,
                includingPropertiesForKeys: nil
            )
            XCTAssertEqual(recoveries.count, 1)
            XCTAssertEqual(try String(contentsOf: recoveries[0]), "occupied")
        }
    }

    func testReplaceMoveUnbacksDirtyOpenDestinationWithoutCreatingTwoCanonicalBuffers() async throws {
        try await withDirectories { sourceURL, recoveryURL in
            let destinationURL = sourceURL.appendingPathComponent("destination", isDirectory: true)
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            let sourceFile = sourceURL.appendingPathComponent("draft.md")
            let occupied = destinationURL.appendingPathComponent("draft.md")
            try Data("moving".utf8).write(to: sourceFile)
            try Data("occupied".utf8).write(to: occupied)
            let source = try Workspace(rootURL: sourceURL, accessSecurityScopedResource: false)
            let destination = try Workspace(rootURL: destinationURL, accessSecurityScopedResource: false)
            let registry = DocumentBufferRegistry()
            let moving = try registry.open(sourceFile, in: source)
            let displaced = try registry.open(occupied, in: destination)
            displaced.replaceText(with: "unsaved occupied")
            let mover = DocumentMover(
                recoveryStore: RecoveryStore(rootURL: recoveryURL)
            )

            let proposal = try await mover.move(
                moving,
                from: source,
                to: destination,
                registry: registry
            )
            guard case .collision(let approvedCollision) = proposal else {
                return XCTFail("Expected collision approval")
            }
            _ = try await mover.move(
                moving,
                from: source,
                to: destination,
                collisionChoice: .replace,
                approvedCollision: approvedCollision,
                registry: registry
            )

            XCTAssertNil(displaced.fileURL)
            XCTAssertEqual(displaced.text, "unsaved occupied")
            XCTAssertEqual(displaced.previousLocator?.relativePath, "draft.md")
            XCTAssertTrue(registry.document(at: occupied, in: destination) === moving)
            XCTAssertEqual(try String(contentsOf: occupied), "moving")
            let recoveries = try FileManager.default.contentsOfDirectory(
                at: recoveryURL,
                includingPropertiesForKeys: nil
            )
            XCTAssertEqual(Set(try recoveries.map { try String(contentsOf: $0) }), [
                "occupied", "unsaved occupied",
            ])
        }
    }

    func testTrashFlushesDirtyTextThenLeavesRecoverableUnbackedBuffer() throws {
        try withDirectories { workspaceURL, recoveryURL in
            let fileURL = workspaceURL.appendingPathComponent("draft.md")
            try Data("base".utf8).write(to: fileURL)
            let workspace = try Workspace(rootURL: workspaceURL, accessSecurityScopedResource: false)
            let document = try workspace.loadDocument(at: fileURL)
            let registry = DocumentBufferRegistry()
            registry.register(document, in: workspace)
            document.replaceText(with: "latest")
            var movedBytes: String?
            let mover = DocumentMover(
                recoveryStore: RecoveryStore(rootURL: recoveryURL),
                trashOperation: { url in
                    movedBytes = try String(contentsOf: url)
                    try FileManager.default.removeItem(at: url)
                    return nil
                }
            )

            try mover.moveToTrash(document, workspace: workspace, registry: registry)

            XCTAssertEqual(movedBytes, "latest")
            XCTAssertNil(document.fileURL)
            XCTAssertEqual(document.previousLocator?.relativePath, "draft.md")
            XCTAssertEqual(document.text, "latest")
            XCTAssertNil(registry.document(at: fileURL, in: workspace))
        }
    }

    func testTrashFailureKeepsBackedCanonicalRegistration() throws {
        try withDirectories { workspaceURL, recoveryURL in
            let fileURL = workspaceURL.appendingPathComponent("draft.md")
            try Data("base".utf8).write(to: fileURL)
            let workspace = try Workspace(rootURL: workspaceURL, accessSecurityScopedResource: false)
            let document = try workspace.loadDocument(at: fileURL)
            let registry = DocumentBufferRegistry()
            registry.register(document, in: workspace)
            document.replaceText(with: "latest")
            let mover = DocumentMover(
                recoveryStore: RecoveryStore(rootURL: recoveryURL),
                trashOperation: { _ in throw SimulatedTrashFailure() }
            )

            XCTAssertThrowsError(
                try mover.moveToTrash(document, workspace: workspace, registry: registry)
            )

            XCTAssertEqual(document.fileURL, fileURL)
            XCTAssertTrue(registry.document(at: fileURL, in: workspace) === document)
            XCTAssertEqual(try String(contentsOf: fileURL), "latest")
        }
    }

    func testOutsideDeletionCancelsPendingSaveAndNeverRecreatesPath() async throws {
        try await withDirectories { workspaceURL, _ in
            let fileURL = workspaceURL.appendingPathComponent("draft.md")
            try Data("base".utf8).write(to: fileURL)
            let workspace = try Workspace(rootURL: workspaceURL, accessSecurityScopedResource: false)
            let document = try workspace.loadDocument(at: fileURL)
            let registry = DocumentBufferRegistry()
            registry.register(document, in: workspace)
            let autosaver = Autosaver(
                workspace: workspace,
                registry: registry,
                delay: .milliseconds(80)
            )
            document.replaceText(with: "local")
            autosaver.documentDidChange(document)
            try FileManager.default.removeItem(at: fileURL)

            try await Task.sleep(for: .milliseconds(150))

            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
            XCTAssertNil(document.fileURL)
            XCTAssertEqual(document.previousLocator?.relativePath, "draft.md")
            XCTAssertEqual(document.text, "local")
            XCTAssertFalse(autosaver.hasPendingSave)
        }
    }

    func testDefaultFolderAuthorizationCreatesAndBookmarksExactRecoverySibling() throws {
        try withDirectories { workspaceURL, _ in
            let documentsURL = workspaceURL.appendingPathComponent("Documents", isDirectory: true)
            try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)

            let grants = try RecoveryAuthorization.createDefaultGrants(in: documentsURL)
            let workspaceResolution = try Workspace.resolveSecurityScopedBookmark(
                grants.workspaceBookmark
            )
            let recoveryResolution = try Workspace.resolveSecurityScopedBookmark(
                grants.recoveryBookmark
            )
            let restored = try RecoveryAuthorization.restore(
                bookmark: grants.recoveryBookmark
            )

            XCTAssertEqual(workspaceResolution.url, documentsURL.appendingPathComponent("Clio"))
            XCTAssertEqual(recoveryResolution.url, documentsURL.appendingPathComponent("Clio Recovery"))
            XCTAssertEqual(restored.store.rootURL, grants.recoveryURL)
            XCTAssertTrue(restored.store.isSecurityScopedAccessActive)
            XCTAssertTrue(FileManager.default.fileExists(atPath: grants.recoveryURL.path))
        }
    }

    func testStaleRecoveryGrantRefreshesBookmarkForPersistence() throws {
        let original = Data("old".utf8)
        let refreshed = Data("new".utf8)
        let url = URL(fileURLWithPath: "/tmp/Clio Recovery")
        let result = try RecoveryAuthorization.bookmarkForPersistence(
            original: original,
            resolution: Workspace.BookmarkResolution(url: url, isStale: true),
            refresh: { refreshedURL in
                XCTAssertEqual(refreshedURL, url)
                return refreshed
            }
        )

        XCTAssertEqual(result, refreshed)
    }

    func testRecoveryPrunesOnlyFilesOlderThanSevenDays() async throws {
        try await withDirectories { _, recoveryURL in
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            let clock = TestClock(now.addingTimeInterval(-RecoveryStore.retention - 1))
            let store = RecoveryStore(rootURL: recoveryURL, now: { clock.now })
            let old = try await store.preserve(
                documentID: DocumentID(),
                filename: "old.md",
                source: "old",
                date: now.addingTimeInterval(-10_000)
            )
            clock.now = now
            let recent = try await store.preserve(
                documentID: DocumentID(),
                filename: "recent.md",
                source: "recent",
                date: now.addingTimeInterval(-20_000)
            )

            XCTAssertFalse(FileManager.default.fileExists(atPath: old.recoveryURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: recent.recoveryURL.path))
            XCTAssertEqual(recent.createdAt, now)
            XCTAssertEqual(recent.sourceModificationDate, now.addingTimeInterval(-20_000))
        }
    }

    func testWatcherReportsNestedCreateMoveModifyAndDelete() async throws {
        try await withDirectories { workspaceURL, _ in
            let nested = workspaceURL.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let watcher = WorkspaceWatcher(workspaceID: WorkspaceID(), rootURL: workspaceURL)
            try await Task.sleep(for: .milliseconds(120))
            let collector = Task { () -> [WorkspaceEventKind] in
                var kinds: [WorkspaceEventKind] = []
                for await event in await watcher.events() {
                    kinds.append(event.kind)
                    if kinds.contains(.created), kinds.contains(.moved), kinds.contains(.deleted) {
                        break
                    }
                }
                return kinds
            }

            let created = nested.appendingPathComponent("one.md")
            try Data("one".utf8).write(to: created)
            try await Task.sleep(for: .milliseconds(120))
            try Data("two".utf8).write(to: created, options: .atomic)
            try await Task.sleep(for: .milliseconds(120))
            let moved = nested.appendingPathComponent("two.md")
            try FileManager.default.moveItem(at: created, to: moved)
            try await Task.sleep(for: .milliseconds(120))
            try FileManager.default.removeItem(at: moved)

            let kinds = try await withTimeout(.seconds(3)) { await collector.value }
            XCTAssertTrue(kinds.contains(.created))
            XCTAssertTrue(kinds.contains(.modified))
            XCTAssertTrue(kinds.contains(.moved))
            XCTAssertTrue(kinds.contains(.deleted))
        }
    }
}

private extension DataSafetyTests {
    final class TestClock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    struct Timeout: Error {}
    struct SimulatedWriteFailure: Error {}
    struct SimulatedTrashFailure: Error {}

    struct FailingAtomicWriter: AtomicFileWriting {
        func replace(
            contents: Data,
            at: URL,
            onlyIf: DiskRevision?
        ) throws -> AtomicReplaceOutcome {
            throw SimulatedWriteFailure()
        }

        func create(contents: Data, at: URL) throws -> Bool {
            throw SimulatedWriteFailure()
        }
    }

    func makeConflict(
        workspaceURL: URL
    ) throws -> (workspace: Workspace, document: Document, fileURL: URL) {
        let fileURL = workspaceURL.appendingPathComponent("draft.md")
        try Data("base".utf8).write(to: fileURL)
        let workspace = try Workspace(
            rootURL: workspaceURL,
            accessSecurityScopedResource: false
        )
        let document = try workspace.loadDocument(at: fileURL)
        document.replaceText(with: "clio")
        try Data("outside".utf8).write(to: fileURL, options: .atomic)
        XCTAssertThrowsError(try workspace.save(document))
        return (workspace, document, fileURL)
    }

    func withDirectories<T>(_ operation: (URL, URL) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioDataSafety-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let recovery = root.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        return try operation(workspace, recovery)
    }

    func withDirectories<T>(
        _ operation: (URL, URL) async throws -> T
    ) async throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioDataSafety-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let recovery = root.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        return try await operation(workspace, recovery)
    }

    func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw Timeout()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw Timeout() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
