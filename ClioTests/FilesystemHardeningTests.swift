import Darwin
import Foundation
import XCTest
@testable import Clio

@MainActor
final class FilesystemHardeningTests: XCTestCase {
    func testStartupMetadataReadersRejectOversizedSparseArtifacts() throws {
        try withDirectory { rootURL in
            let journalURL = rootURL.appendingPathComponent("Journal", isDirectory: true)
            let workspaceURL = rootURL.appendingPathComponent("Workspace", isDirectory: true)
            try FileManager.default.createDirectory(
                at: journalURL,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: workspaceURL,
                withIntermediateDirectories: true
            )

            let atomicID = UUID()
            let atomicManifest = workspaceURL.appendingPathComponent(
                AtomicWriteTransactions.manifestPrefix
                    + atomicID.uuidString.lowercased()
                    + AtomicWriteTransactions.manifestSuffix
            )
            try makeSparseFile(
                at: atomicManifest,
                byteCount: AtomicWriteTransactions.maximumManifestByteCount + 1
            )

            let moveID = UUID()
            let moveManifest = workspaceURL.appendingPathComponent(
                InterruptedMoveTransactions.manifestPrefix
                    + moveID.uuidString.lowercased()
                    + InterruptedMoveTransactions.manifestSuffix
            )
            try makeSparseFile(
                at: moveManifest,
                byteCount: InterruptedMoveTransactions.maximumManifestByteCount + 1
            )

            let recoveryRecord = journalURL.appendingPathComponent(
                "buffer-(UUID().uuidString.lowercased()).clio-recovery"
            )
            try makeSparseFile(
                at: recoveryRecord,
                byteCount: CrashRecoveryJournal.maximumRecordByteCount + 1
            )

            let journal = CrashRecoveryJournal(rootURL: journalURL)
            XCTAssertEqual(
                try AtomicWriteTransactions.recoverInterruptedTransactions(
                    in: workspaceURL,
                    journal: journal
                ),
                0
            )
            XCTAssertEqual(
                try InterruptedMoveTransactions.recover(
                    in: workspaceURL,
                    journal: journal
                ),
                0
            )
            XCTAssertTrue(try journal.validRecords().isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: atomicManifest.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: moveManifest.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryRecord.path))
        }
    }

    func testIdentityStoreRejectsOversizedSparseStartupFile() throws {
        try withDirectory { rootURL in
            let storageURL = rootURL.appendingPathComponent("DocumentIdentities.json")
            try makeSparseFile(
                at: storageURL,
                byteCount: DocumentIdentityStore.maximumStorageByteCount + 1
            )
            let store = DocumentIdentityStore(storageURL: storageURL)
            let locator = try DocumentLocator(
                workspaceID: WorkspaceID(),
                relativePath: "draft.md"
            )

            XCTAssertThrowsError(
                try store.resolve(DocumentIdentityCandidate(locator: locator))
            ) { error in
                guard case DocumentIdentityStore.StoreError.corruptStore = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testOversizedSparseDocumentIsRejectedBeforePayloadAllocation() throws {
        try withDirectory { rootURL in
            let fileURL = rootURL.appendingPathComponent("oversized.md")
            XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: nil))
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.truncate(
                atOffset: UInt64(PerformanceContract.safeLargeFileByteLimit + 1)
            )
            try handle.close()

            XCTAssertThrowsError(try Document(contentsOf: fileURL)) { error in
                guard case DocumentRevisionReader.RevisionError.fileTooLarge(
                    let rejectedURL,
                    let byteCount,
                    let maximumByteCount
                ) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(rejectedURL, fileURL)
                XCTAssertEqual(
                    byteCount,
                    Int64(PerformanceContract.safeLargeFileByteLimit + 1)
                )
                XCTAssertEqual(
                    maximumByteCount,
                    Int64(PerformanceContract.safeLargeFileByteLimit)
                )
            }
        }
    }

    func testStreamingRevisionMatchesSnapshotDigest() throws {
        try withDirectory { rootURL in
            let fileURL = rootURL.appendingPathComponent("unicode.md")
            let data = Data(String(repeating: "Clio café 日本語\n", count: 100_000).utf8)
            try data.write(to: fileURL)

            let snapshot = try DocumentRevisionReader.snapshot(at: fileURL)
            let revision = try DocumentRevisionReader.revision(at: fileURL)

            XCTAssertEqual(snapshot.data, data)
            XCTAssertEqual(revision.byteCount, Int64(data.count))
            XCTAssertEqual(revision.contentDigest, snapshot.revision.contentDigest)
        }
    }

    func testAtomicReplacePreservesModeAndExtendedMetadata() throws {
        try withDirectory { rootURL in
            let fileURL = rootURL.appendingPathComponent("metadata.md")
            try Data("before".utf8).write(to: fileURL)
            XCTAssertEqual(chmod(fileURL.path, 0o640), 0)
            try setExtendedAttribute(
                name: "com.olympus.clio.test",
                value: Data("retained".utf8),
                at: fileURL
            )
            let expected = try DocumentRevisionReader.revision(at: fileURL)

            XCTAssertEqual(
                try AtomicFileWriter().replace(
                    contents: Data("after".utf8),
                    at: fileURL,
                    onlyIf: expected
                ),
                .replaced
            )

            var status = stat()
            XCTAssertEqual(lstat(fileURL.path, &status), 0)
            XCTAssertEqual(status.st_mode & 0o777, 0o640)
            XCTAssertEqual(
                try extendedAttribute(name: "com.olympus.clio.test", at: fileURL),
                Data("retained".utf8)
            )
            XCTAssertEqual(try Data(contentsOf: fileURL), Data("after".utf8))
        }
    }

    func testReadOnlyDestinationIsNeverBypassedByAtomicRename() throws {
        try withDirectory { rootURL in
            let fileURL = rootURL.appendingPathComponent("read-only.md")
            let original = Data("outside bytes".utf8)
            try original.write(to: fileURL)
            let expected = try DocumentRevisionReader.revision(at: fileURL)
            XCTAssertEqual(chmod(fileURL.path, 0o444), 0)
            defer { _ = chmod(fileURL.path, 0o644) }

            XCTAssertThrowsError(
                try AtomicFileWriter().replace(
                    contents: Data("must not install".utf8),
                    at: fileURL,
                    onlyIf: expected
                )
            )
            XCTAssertEqual(try Data(contentsOf: fileURL), original)
            XCTAssertTrue(try transactionArtifacts(in: rootURL).isEmpty)
        }
    }

    func testInjectedOutOfSpaceBeforeCandidateLeavesCanonicalBytesRecoverable() throws {
        try withDirectory { rootURL in
            let journalURL = rootURL.appendingPathComponent("Journal", isDirectory: true)
            let workspaceURL = rootURL.appendingPathComponent("Workspace", isDirectory: true)
            try FileManager.default.createDirectory(
                at: workspaceURL,
                withIntermediateDirectories: true
            )
            let fileURL = workspaceURL.appendingPathComponent("draft.md")
            let original = Data("canonical outside bytes".utf8)
            try original.write(to: fileURL)
            let expected = try DocumentRevisionReader.revision(at: fileURL)
            let writer = AtomicFileWriter(phaseHook: { phase in
                if phase == .manifestSynced {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
            })

            XCTAssertThrowsError(
                try writer.replace(
                    contents: Data("local bytes".utf8),
                    at: fileURL,
                    onlyIf: expected
                )
            )
            XCTAssertEqual(try Data(contentsOf: fileURL), original)

            let journal = CrashRecoveryJournal(rootURL: journalURL)
            _ = try AtomicWriteTransactions.recoverInterruptedTransactions(
                in: workspaceURL,
                journal: journal
            )
            XCTAssertEqual(try Data(contentsOf: fileURL), original)
            XCTAssertTrue(try transactionArtifacts(in: workspaceURL).isEmpty)
        }
    }
}

private extension FilesystemHardeningTests {
    func withDirectory(_ operation: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClioFilesystemHardening-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try operation(url)
    }

    func transactionArtifacts(in rootURL: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(AtomicWriteTransactions.manifestPrefix)
                || $0.lastPathComponent.hasPrefix(AtomicWriteTransactions.temporaryPrefix)
        }
    }

    func makeSparseFile(at url: URL, byteCount: Int64) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(byteCount))
        try handle.close()
    }

    func setExtendedAttribute(name: String, value: Data, at url: URL) throws {
        let result = value.withUnsafeBytes { bytes in
            setxattr(url.path, name, bytes.baseAddress, bytes.count, 0, 0)
        }
        guard result == 0 else { throw posixError(for: url) }
    }

    func extendedAttribute(name: String, at url: URL) throws -> Data {
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length >= 0 else { throw posixError(for: url) }
        var data = Data(count: length)
        let readLength = data.withUnsafeMutableBytes { bytes in
            getxattr(url.path, name, bytes.baseAddress, bytes.count, 0, 0)
        }
        guard readLength == length else { throw posixError(for: url) }
        return data
    }

    func posixError(for url: URL) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSFilePathErrorKey: url.path]
        )
    }
}
