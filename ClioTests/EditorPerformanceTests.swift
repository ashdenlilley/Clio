import AppKit
import XCTest
@testable import Clio

final class EditorPerformanceTests: XCTestCase {
    @MainActor
    func testRevisionAwareSynchronizationDoesNotReplaceBufferAfterLocalEdit() {
        var model = "alpha"
        var revision: UInt64 = 0
        let applyEdit: @MainActor (MarkdownTextEdit) -> Void = { edit in
            if let updated = MarkdownTextEditApplier.applying(edit, to: model) {
                model = updated
                revision &+= 1
            }
        }
        let configuration = EditorConfiguration(isFocusModeEnabled: false)
        let coordinator = EditorCoordinator(
            configuration: configuration,
            onTextEdit: applyEdit
        )
        let textView = EditorTextView.makeTextKit2TextView()
        let surface = EditorContainerView(textView: textView)
        let bufferID = UUID()
        coordinator.attach(to: surface)
        coordinator.update(
            text: model,
            contentGeneration: BufferGeneration(bufferID: bufferID, revision: revision),
            configuration: configuration,
            onTextEdit: applyEdit
        )

        let insertion = NSRange(location: textView.textStorage?.length ?? 0, length: 0)
        XCTAssertTrue(coordinator.textView(
            textView,
            shouldChangeTextIn: insertion,
            replacementString: "!"
        ))
        textView.textStorage?.replaceCharacters(in: insertion, with: "!")
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        coordinator.update(
            text: model,
            contentGeneration: BufferGeneration(bufferID: bufferID, revision: revision),
            configuration: configuration,
            onTextEdit: applyEdit
        )

        XCTAssertEqual(model, "alpha!")
        XCTAssertEqual(coordinator.acceptedEditorMutationCount, 1)
        XCTAssertEqual(coordinator.externalBufferReplacementCount, 1)

        model = "bravo!"
        revision &+= 1
        coordinator.update(
            text: model,
            contentGeneration: BufferGeneration(bufferID: bufferID, revision: revision),
            configuration: configuration,
            onTextEdit: applyEdit
        )
        XCTAssertEqual(textView.string, "bravo!")
        XCTAssertEqual(coordinator.externalBufferReplacementCount, 2)

        model = "other!"
        coordinator.update(
            text: model,
            contentGeneration: BufferGeneration(bufferID: UUID(), revision: revision),
            configuration: configuration,
            onTextEdit: applyEdit
        )
        XCTAssertEqual(textView.string, "other!")
        XCTAssertEqual(coordinator.externalBufferReplacementCount, 3)
    }

    @MainActor
    func testRealTextViewTailInsertionsKeepMainActorHeartbeatWithinFrameBudget() async {
        for byteCount in [10, 50].map({ $0 * 1_024 * 1_024 }) {
            let line = String(repeating: "a", count: 79) + "\n"
            let source = String(repeating: line, count: byteCount / line.utf8.count)
                + String(repeating: "a", count: byteCount % line.utf8.count)
            var capturedEdit: MarkdownTextEdit?
            let sink: @MainActor (MarkdownTextEdit) -> Void = { capturedEdit = $0 }
            let configuration = EditorConfiguration(
                isSpellCheckingEnabled: false,
                isTypewriterScrollingEnabled: false,
                isFocusModeEnabled: false
            )
            let coordinator = EditorCoordinator(
                configuration: configuration,
                onTextEdit: sink
            )
            let textView = EditorTextView.makeTextKit2TextView()
            let surface = EditorContainerView(textView: textView)
            coordinator.attach(to: surface)
            coordinator.update(
                text: source,
                contentGeneration: BufferGeneration(revision: 0),
                configuration: configuration,
                onTextEdit: sink
            )
            let insertion = NSRange(location: byteCount, length: 0)
            let clock = ContinuousClock()
            let start = clock.now
            XCTAssertTrue(coordinator.textView(
                textView,
                shouldChangeTextIn: insertion,
                replacementString: "!"
            ))
            textView.textStorage?.replaceCharacters(in: insertion, with: "!")
            coordinator.textDidChange(
                Notification(name: NSText.didChangeNotification, object: textView)
            )
            let elapsed = start.duration(to: clock.now)

            XCTAssertEqual(
                capturedEdit,
                MarkdownTextEdit(
                    replacedRange: UTF16Range(location: byteCount, length: 0),
                    replacement: "!"
                )
            )
            XCTAssertLessThan(
                elapsed,
                .milliseconds(16),
                "\(byteCount / 1_024 / 1_024) MiB tail edit stalled the main actor for \(elapsed)"
            )

            // Give the run loop an opportunity to prove the edit returned to
            // the main actor instead of hiding deferred synchronous work.
            await Task.yield()
        }
    }

    @MainActor
    func testRapidLargeSessionEditsBatchToExactDurableBytes() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioEditorPerformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let workspace = try Workspace(
            rootURL: directoryURL,
            accessSecurityScopedResource: false
        )

        for mebibytes in [10, 50] {
            let byteCount = mebibytes * 1_024 * 1_024
            let line = String(repeating: "word ", count: 15) + "end\n"
            let source = String(repeating: line, count: byteCount / line.utf8.count)
                + String(repeating: "x", count: byteCount % line.utf8.count)
            let fileURL = directoryURL.appendingPathComponent("large-\(mebibytes).md")
            try Data(source.utf8).write(to: fileURL)
            let registry = DocumentBufferRegistry(
                identityStore: DocumentIdentityStore(storageURL: nil)
            )
            let session = EditorSession(openingMode: .mostRecent)
            await session.activateInBackground(
                in: workspace,
                documentURLs: [fileURL],
                registry: registry
            )
            let document = try XCTUnwrap(session.document)
            let autosaver = registry.autosaver(for: document, in: workspace)

            let suffix = (0..<100).map { String($0 % 10) }.joined()
            let clock = ContinuousClock()
            let enqueueStarted = clock.now
            for (offset, character) in suffix.enumerated() {
                session.editorTextDidChange(MarkdownTextEdit(
                    replacedRange: UTF16Range(
                        location: byteCount + offset,
                        length: 0
                    ),
                    replacement: String(character)
                ))
            }
            XCTAssertLessThan(
                enqueueStarted.duration(to: clock.now),
                .milliseconds(16),
                "\(mebibytes) MiB edit burst blocked the main actor"
            )

            let modelDeadline = clock.now.advanced(by: .seconds(5))
            var heartbeats = 0
            while session.contentRevision != 100, clock.now < modelDeadline {
                try await Task.sleep(for: .milliseconds(5))
                heartbeats += 1
            }

            let expected = source + suffix
            XCTAssertGreaterThan(heartbeats, 0)
            XCTAssertEqual(session.contentRevision, 100)
            XCTAssertEqual(session.draftText, expected)
            XCTAssertLessThanOrEqual(session.editorMaterializationCount, 2)
            XCTAssertLessThanOrEqual(session.editorPublicationCount, 2)

            try await autosaver.flushAsync(document)
            XCTAssertLessThanOrEqual(autosaver.backgroundSaveAttemptCount, 2)

            let saveDeadline = clock.now.advanced(by: .seconds(5))
            while ((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    != expected.utf8.count), clock.now < saveDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(try Data(contentsOf: fileURL), Data(expected.utf8))
            session.deactivate()
        }
    }

    @MainActor
    func testFiftyMiBExternalModifyEventKeepsMainActorResponsive() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioExternalHeartbeat-\(UUID().uuidString)", isDirectory: true)
        let recoveryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioExternalHeartbeatRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recoveryURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
            try? FileManager.default.removeItem(at: recoveryURL)
        }

        let byteCount = 50 * 1_024 * 1_024
        let fileURL = directoryURL.appendingPathComponent("large.md")
        try Data(repeating: 0x61, count: byteCount).write(to: fileURL)
        let workspace = try Workspace(
            rootURL: directoryURL,
            accessSecurityScopedResource: false
        )
        let registry = DocumentBufferRegistry(
            identityStore: DocumentIdentityStore(storageURL: nil)
        )
        let document = try await registry.openInBackground(fileURL, in: workspace)
        let defaultsName = "ClioExternalHeartbeat.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let state = AppState(
            defaults: defaults,
            initialWorkspace: workspace,
            recoveryStore: RecoveryStore(rootURL: recoveryURL),
            documentRegistry: registry
        )

        var outside = Data(repeating: 0x61, count: byteCount)
        outside[outside.count - 1] = 0x62
        try outside.write(to: fileURL, options: .atomic)
        let event = WorkspaceEvent(
            workspaceID: workspace.id,
            kind: .modified,
            fileURL: fileURL,
            origin: .external
        )
        let clock = ContinuousClock()
        var startedAt: ContinuousClock.Instant?
        var finished = false
        let reconciliation = Task { @MainActor in
            startedAt = clock.now
            await state.reconcileWorkspaceEvent(event, in: workspace)
            finished = true
        }

        while startedAt == nil { await Task.yield() }
        let initialReturnGap = startedAt!.duration(to: clock.now)
        var priorHeartbeat = clock.now
        var maximumHeartbeatGap = Duration.zero
        var heartbeatCount = 0
        while !finished {
            await Task.yield()
            let now = clock.now
            maximumHeartbeatGap = max(maximumHeartbeatGap, priorHeartbeat.duration(to: now))
            priorHeartbeat = now
            heartbeatCount += 1
        }
        await reconciliation.value

        XCTAssertLessThan(
            initialReturnGap,
            .milliseconds(16),
            "Workspace event did not yield MainActor before reading 50 MiB"
        )
        XCTAssertLessThan(
            startedAt!.duration(to: priorHeartbeat),
            .seconds(5),
            "External reconciliation did not complete within the safe-file budget"
        )
        XCTAssertLessThan(
            maximumHeartbeatGap,
            .milliseconds(16),
            "50 MiB outside read blocked MainActor for \(maximumHeartbeatGap)"
        )
        XCTAssertGreaterThan(heartbeatCount, 0)
        XCTAssertEqual(document.utf8ByteCount, byteCount)
        XCTAssertEqual(Data(document.text.utf8), outside)
    }

    @MainActor
    func testFiftyMiBAsyncAutosaveYieldsMainActorAndPersistsExactBytes() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioAutosaveHeartbeat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let byteCount = 50 * 1_024 * 1_024
        let fileURL = directoryURL.appendingPathComponent("large.md")
        let original = Data(repeating: 0x61, count: byteCount)
        try original.write(to: fileURL)
        let workspace = try Workspace(
            rootURL: directoryURL,
            accessSecurityScopedResource: false
        )
        let document = try await workspace.loadDocumentInBackground(at: fileURL)
        var expected = original
        expected[expected.count - 1] = 0x62
        document.replaceText(with: String(decoding: expected, as: UTF8.self))
        let autosaver = Autosaver(workspace: workspace, delay: .seconds(30))
        autosaver.documentDidChange(document)

        let clock = ContinuousClock()
        var startedAt: ContinuousClock.Instant?
        var finished = false
        var saveError: Error?
        let save = Task { @MainActor in
            startedAt = clock.now
            do {
                try await autosaver.flushAsync(document)
            } catch {
                saveError = error
            }
            finished = true
        }

        while startedAt == nil { await Task.yield() }
        let initialReturnGap = startedAt!.duration(to: clock.now)
        var priorHeartbeat = clock.now
        var maximumHeartbeatGap = Duration.zero
        var heartbeatCount = 0
        while !finished {
            await Task.yield()
            let now = clock.now
            maximumHeartbeatGap = max(maximumHeartbeatGap, priorHeartbeat.duration(to: now))
            priorHeartbeat = now
            heartbeatCount += 1
        }
        await save.value

        XCTAssertNil(saveError)
        XCTAssertLessThan(initialReturnGap, .milliseconds(16))
        XCTAssertLessThan(maximumHeartbeatGap, .milliseconds(16))
        XCTAssertGreaterThan(heartbeatCount, 0)
        XCTAssertEqual(autosaver.backgroundSaveAttemptCount, 1)
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(try Data(contentsOf: fileURL), expected)
    }

    @MainActor
    func testFiftyMiBOpenHydratesOffMainAndRegistersExactBuffer() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioOpenHeartbeat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let byteCount = 50 * 1_024 * 1_024
        let fileURL = directoryURL.appendingPathComponent("large.md")
        try Data(repeating: 0x61, count: byteCount).write(to: fileURL)
        let workspace = try Workspace(
            rootURL: directoryURL,
            accessSecurityScopedResource: false
        )
        let registry = DocumentBufferRegistry(
            identityStore: DocumentIdentityStore(storageURL: nil)
        )

        let clock = ContinuousClock()
        var startedAt: ContinuousClock.Instant?
        var finished = false
        var opened: Document?
        var openError: Error?
        let task = Task { @MainActor in
            startedAt = clock.now
            do {
                opened = try await registry.openInBackground(fileURL, in: workspace)
            } catch {
                openError = error
            }
            finished = true
        }

        while startedAt == nil { await Task.yield() }
        let initialReturnGap = startedAt!.duration(to: clock.now)
        var previous = clock.now
        var maximumHeartbeatGap = Duration.zero
        var heartbeatCount = 0
        while !finished {
            await Task.yield()
            let now = clock.now
            maximumHeartbeatGap = max(maximumHeartbeatGap, previous.duration(to: now))
            previous = now
            heartbeatCount += 1
        }
        await task.value

        XCTAssertNil(openError)
        XCTAssertLessThan(initialReturnGap, .milliseconds(16))
        XCTAssertLessThan(maximumHeartbeatGap, .milliseconds(16))
        XCTAssertGreaterThan(heartbeatCount, 0)
        let document = try XCTUnwrap(opened)
        XCTAssertEqual(document.utf8ByteCount, byteCount)
        XCTAssertEqual(document.text.utf8.first, 0x61)
        XCTAssertEqual(document.text.utf8.last, 0x61)
        XCTAssertTrue(registry.document(at: fileURL, in: workspace) === document)
    }

    @MainActor
    func testLegacySynchronousSaveRefusesFiftyMiBOutsideSideBeforeReadingIt() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioSyncRefusal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = directoryURL.appendingPathComponent("draft.md")
        try Data("base".utf8).write(to: fileURL)
        let workspace = try Workspace(
            rootURL: directoryURL,
            accessSecurityScopedResource: false
        )
        let document = try workspace.loadDocument(at: fileURL)
        document.replaceText(with: "local")
        let outside = Data(repeating: 0x61, count: 50 * 1_024 * 1_024)
        try outside.write(to: fileURL, options: .atomic)

        let clock = ContinuousClock()
        let started = clock.now
        XCTAssertThrowsError(try workspace.save(document)) { error in
            guard let workspaceError = error as? Workspace.WorkspaceError,
                  case .backgroundOperationRequired(let refusedURL) = workspaceError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(refusedURL, fileURL)
        }

        XCTAssertLessThan(started.duration(to: clock.now), .milliseconds(16))
        XCTAssertTrue(document.isDirty)
        XCTAssertNil(document.conflict)
        XCTAssertEqual(try Data(contentsOf: fileURL), outside)
    }

    @MainActor
    func testFiftyMiBConflictResolutionYieldsMainActorAndKeepsExactClioBytes() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioConflictHeartbeat-\(UUID().uuidString)", isDirectory: true)
        let recoveryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioConflictHeartbeatRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recoveryURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
            try? FileManager.default.removeItem(at: recoveryURL)
        }

        let byteCount = 50 * 1_024 * 1_024
        let fileURL = directoryURL.appendingPathComponent("large.md")
        let original = Data(repeating: 0x61, count: byteCount)
        try original.write(to: fileURL)
        let workspace = try Workspace(
            rootURL: directoryURL,
            accessSecurityScopedResource: false
        )
        let registry = DocumentBufferRegistry(
            identityStore: DocumentIdentityStore(storageURL: nil)
        )
        let document = try await registry.openInBackground(fileURL, in: workspace)
        var local = original
        local[local.count - 1] = 0x62
        document.replaceText(with: String(decoding: local, as: UTF8.self))
        var outside = original
        outside[outside.count - 1] = 0x63
        try outside.write(to: fileURL, options: .atomic)
        try await workspace.reconcileExternalChangeInBackground(for: document)
        XCTAssertNotNil(document.conflict)
        let resolver = ConflictResolver(
            recoveryStore: RecoveryStore(rootURL: recoveryURL)
        )

        let clock = ContinuousClock()
        var startedAt: ContinuousClock.Instant?
        var finished = false
        var resolutionError: Error?
        let resolution = Task { @MainActor in
            startedAt = clock.now
            do {
                _ = try await resolver.resolve(
                    .keepClio,
                    document: document,
                    workspace: workspace,
                    registry: registry
                )
            } catch {
                resolutionError = error
            }
            finished = true
        }

        while startedAt == nil { await Task.yield() }
        let initialReturnGap = startedAt!.duration(to: clock.now)
        var previous = clock.now
        var maximumHeartbeatGap = Duration.zero
        var heartbeatCount = 0
        while !finished {
            await Task.yield()
            let now = clock.now
            maximumHeartbeatGap = max(maximumHeartbeatGap, previous.duration(to: now))
            previous = now
            heartbeatCount += 1
        }
        await resolution.value

        XCTAssertNil(resolutionError)
        XCTAssertLessThan(initialReturnGap, .milliseconds(16))
        XCTAssertLessThan(maximumHeartbeatGap, .milliseconds(16))
        XCTAssertGreaterThan(heartbeatCount, 0)
        XCTAssertNil(document.conflict)
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(try Data(contentsOf: fileURL), local)
        let recoveries = try FileManager.default.contentsOfDirectory(
            at: recoveryURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(recoveries.count, 1)
        XCTAssertEqual(try Data(contentsOf: recoveries[0]), outside)
    }

    @MainActor
    func testRenameImmediatelyAfterLargeEditSettlesExactBytesBeforeMove() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioEditorRename-\(UUID().uuidString)", isDirectory: true)
        let recoveryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioEditorRenameRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: recoveryURL,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
            try? FileManager.default.removeItem(at: recoveryURL)
        }

        let source = String(repeating: "large source line\n", count: 32_768)
        let sourceURL = directoryURL.appendingPathComponent("draft.md")
        try Data(source.utf8).write(to: sourceURL)
        let workspace = try Workspace(
            rootURL: directoryURL,
            accessSecurityScopedResource: false
        )
        let registry = DocumentBufferRegistry()
        let mover = DocumentMover(
            recoveryStore: RecoveryStore(rootURL: recoveryURL)
        )
        let session = EditorSession(openingMode: .mostRecent)
        await session.activateInBackground(
            in: workspace,
            documentURLs: [sourceURL],
            registry: registry,
            documentMover: mover
        )

        let suffix = "saved-before-rename"
        session.editorTextDidChange(MarkdownTextEdit(
            replacedRange: UTF16Range(
                location: (source as NSString).length,
                length: 0
            ),
            replacement: suffix
        ))
        XCTAssertTrue(session.hasUnsettledEditorEdits)
        XCTAssertFalse(session.flushForLifecycleEvent())

        let outcome = try await session.rename(to: "renamed.md")
        let destinationURL = directoryURL.appendingPathComponent("renamed.md")
        let expected = source + suffix

        XCTAssertEqual(
            outcome,
            .completed(try workspace.locator(for: destinationURL))
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try Data(contentsOf: destinationURL), Data(expected.utf8))
        XCTAssertEqual(session.draftText, expected)
        XCTAssertFalse(session.hasUnsettledEditorEdits)
    }

    @MainActor
    func testDirectCrossWorkspaceMoveSettlesImmediateLargeEdit() async throws {
        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioEditorMoveSource-\(UUID().uuidString)", isDirectory: true)
        let destinationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioEditorMoveDestination-\(UUID().uuidString)", isDirectory: true)
        let recoveryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioEditorMoveRecovery-\(UUID().uuidString)", isDirectory: true)
        for url in [sourceRoot, destinationRoot, recoveryURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: destinationRoot)
            try? FileManager.default.removeItem(at: recoveryURL)
        }

        let source = String(repeating: "cross workspace line\n", count: 32_768)
        let sourceURL = sourceRoot.appendingPathComponent("draft.md")
        try Data(source.utf8).write(to: sourceURL)
        let sourceWorkspace = try Workspace(
            rootURL: sourceRoot,
            accessSecurityScopedResource: false
        )
        let destinationWorkspace = try Workspace(
            rootURL: destinationRoot,
            accessSecurityScopedResource: false
        )
        let registry = DocumentBufferRegistry()
        let mover = DocumentMover(
            recoveryStore: RecoveryStore(rootURL: recoveryURL)
        )
        let session = EditorSession(openingMode: .mostRecent)
        await session.activateInBackground(
            in: sourceWorkspace,
            documentURLs: [sourceURL],
            registry: registry,
            documentMover: mover
        )
        let document = try XCTUnwrap(session.document)

        let suffix = "moved-after-edit"
        session.editorTextDidChange(MarkdownTextEdit(
            replacedRange: UTF16Range(
                location: (source as NSString).length,
                length: 0
            ),
            replacement: suffix
        ))

        let outcome = try await mover.move(
            document,
            from: sourceWorkspace,
            to: destinationWorkspace,
            registry: registry
        )
        let destinationURL = destinationRoot.appendingPathComponent("draft.md")

        XCTAssertEqual(
            outcome,
            .completed(try destinationWorkspace.locator(for: destinationURL))
        )
        XCTAssertEqual(try Data(contentsOf: destinationURL), Data((source + suffix).utf8))
        XCTAssertEqual(session.fileURL, destinationURL)
        XCTAssertEqual(session.draftText, source + suffix)
        XCTAssertFalse(session.hasUnsettledEditorEdits)
    }

    @MainActor
    func testTrashRefusesImmediateLargeEditUntilSettled() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioEditorTrash-\(UUID().uuidString)", isDirectory: true)
        let recoveryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioEditorTrashRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: recoveryURL,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
            try? FileManager.default.removeItem(at: recoveryURL)
        }

        let source = String(repeating: "t", count: 50 * 1_024 * 1_024)
        let sourceURL = directoryURL.appendingPathComponent("draft.md")
        let trashedURL = directoryURL.appendingPathComponent("trashed.md")
        try Data(source.utf8).write(to: sourceURL)
        let workspace = try Workspace(
            rootURL: directoryURL,
            accessSecurityScopedResource: false
        )
        var trashInvocationCount = 0
        let mover = DocumentMover(
            recoveryStore: RecoveryStore(rootURL: recoveryURL),
            trashOperation: { url in
                trashInvocationCount += 1
                try FileManager.default.moveItem(at: url, to: trashedURL)
                return trashedURL
            }
        )
        let session = EditorSession(openingMode: .mostRecent)
        await session.activateInBackground(
            in: workspace,
            documentURLs: [sourceURL],
            documentMover: mover
        )

        let suffix = "kept-before-trash"
        session.editorTextDidChange(MarkdownTextEdit(
            replacedRange: UTF16Range(
                location: (source as NSString).length,
                length: 0
            ),
            replacement: suffix
        ))

        XCTAssertThrowsError(try session.moveToTrash())
        XCTAssertEqual(trashInvocationCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))

        try await session.settlePendingEditorEdits()
        XCTAssertThrowsError(try session.moveToTrash())
        try await session.moveToTrashNow()

        XCTAssertEqual(trashInvocationCount, 1)
        XCTAssertEqual(try Data(contentsOf: trashedURL), Data((source + suffix).utf8))
    }

    @MainActor
    func testExternalChangeWaitsForImmediateLargeEditAndCreatesConflict() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioEditorExternal-\(UUID().uuidString)", isDirectory: true)
        let recoveryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioEditorExternalRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: recoveryURL,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
            try? FileManager.default.removeItem(at: recoveryURL)
        }

        let source = String(repeating: "external safety line\n", count: 32_768)
        let fileURL = directoryURL.appendingPathComponent("draft.md")
        try Data(source.utf8).write(to: fileURL)
        let workspace = try Workspace(
            rootURL: directoryURL,
            accessSecurityScopedResource: false
        )
        let defaultsName = "ClioEditorExternal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let state = AppState(
            defaults: defaults,
            initialWorkspace: workspace,
            recoveryStore: RecoveryStore(rootURL: recoveryURL)
        )
        let session = EditorSession(openingMode: .mostRecent)
        state.register(session)
        try await Task.sleep(for: .milliseconds(120))

        let suffix = "local-before-outside-change"
        session.editorTextDidChange(MarkdownTextEdit(
            replacedRange: UTF16Range(
                location: (source as NSString).length,
                length: 0
            ),
            replacement: suffix
        ))
        try Data("outside".utf8).write(to: fileURL, options: .atomic)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while session.activeConflict == nil, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(session.draftText, source + suffix)
        XCTAssertEqual(session.activeConflict?.clio.source, source + suffix)
        XCTAssertEqual(session.activeConflict?.external.source, "outside")
        XCTAssertFalse(session.hasUnsettledEditorEdits)
        XCTAssertEqual(try String(contentsOf: fileURL), "outside")
    }

    @MainActor
    func testInvalidLargeDeltaMakesEveryMutationBoundaryRefuse() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioEditorInvalid-\(UUID().uuidString)", isDirectory: true)
        let recoveryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioEditorInvalidRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recoveryURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
            try? FileManager.default.removeItem(at: recoveryURL)
        }

        let source = String(repeating: "invalid delta line\n", count: 32_768)
        let fileURL = directoryURL.appendingPathComponent("draft.md")
        try Data(source.utf8).write(to: fileURL)
        let workspace = try Workspace(
            rootURL: directoryURL,
            accessSecurityScopedResource: false
        )
        let registry = DocumentBufferRegistry()
        let mover = DocumentMover(
            recoveryStore: RecoveryStore(rootURL: recoveryURL),
            trashOperation: { _ in XCTFail("Trash must not run"); return nil }
        )
        let session = EditorSession(openingMode: .mostRecent)
        await session.activateInBackground(
            in: workspace,
            documentURLs: [fileURL],
            registry: registry,
            documentMover: mover
        )
        session.editorTextDidChange(MarkdownTextEdit(
            replacedRange: UTF16Range(location: Int.max / 2, length: 0),
            replacement: "unsafely positioned"
        ))

        do {
            try await session.settlePendingEditorEdits()
            XCTFail("Invalid editor delta unexpectedly settled")
        } catch {
            XCTAssertTrue(error is EditorSynchronizationError)
        }
        XCTAssertTrue(session.hasUnsettledEditorEdits)
        XCTAssertThrowsError(try session.flush())
        XCTAssertFalse(session.flushForLifecycleEvent())
        XCTAssertThrowsError(try session.moveToTrash())
        do {
            _ = try await session.rename(to: "renamed.md")
            XCTFail("Rename unexpectedly ignored the invalid editor delta")
        } catch {
            XCTAssertTrue(error is EditorSynchronizationError)
        }
        XCTAssertEqual(session.draftText, source)
        XCTAssertEqual(try Data(contentsOf: fileURL), Data(source.utf8))
    }

    @MainActor
    func testLargeWordCountRunsOffMainAndOnlyLatestRevisionPublishes() async throws {
        let session = EditorSession(openingMode: .newDocument)
        let stale = String(repeating: "stale ", count: 300_000)
        let latest = String(repeating: "latest ", count: 280_000)
        session.draftText = stale
        session.draftText = latest

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var heartbeats = 0
        while session.wordCount != 280_000, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            heartbeats += 1
        }

        XCTAssertEqual(session.wordCount, 280_000)
        XCTAssertGreaterThan(heartbeats, 0)
    }

    func testConflictPreviewBoundsDecodeAndDisplayedLineLength() async throws {
        let prefix = Data(String(repeating: "a", count: 5 * 1_024 * 1_024).utf8)
        let external = Data(String(repeating: "b", count: 5 * 1_024 * 1_024).utf8)
        let workspaceID = WorkspaceID()
        let conflict = try DocumentConflict(
            documentID: DocumentID(),
            locator: DocumentLocator(workspaceID: workspaceID, relativePath: "draft.md"),
            generation: BufferGeneration(),
            clio: ConflictSide(
                modificationDate: .distantPast,
                revision: nil,
                data: prefix
            ),
            external: ConflictSide(
                modificationDate: .now,
                revision: nil,
                data: external
            )
        )

        let preview = await ConflictPreviewBuilder.preview(for: conflict)

        XCTAssertLessThan(preview.utf8.count, 2_048)
        XCTAssertTrue(preview.contains("outside this bounded preview"))
        XCTAssertTrue(preview.contains("− "))
        XCTAssertTrue(preview.contains("+ "))
    }
}
