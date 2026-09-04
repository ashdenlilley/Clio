import Foundation
import Observation

@MainActor
@Observable
final class Document: Identifiable {
    enum ReadError: LocalizedError, Equatable {
        case invalidUTF8(URL)

        var errorDescription: String? {
            switch self {
            case .invalidUTF8(let url):
                "\(url.lastPathComponent) is not a UTF-8 text file."
            }
        }
    }

    struct Snapshot: Sendable, Equatable {
        let documentID: DocumentID
        let revision: UInt64
        let text: String
        let fileURL: URL?
        let preferredFilename: String
        let isDirty: Bool
        let expectedDiskRevision: DiskRevision?
        let previousLocator: DocumentLocator?
    }

    nonisolated static let defaultFilename = "untitled.md"

    let id: DocumentID
    private(set) var preferredFilename: String
    private(set) var text: String
    private(set) var fileURL: URL?
    private(set) var isDirty: Bool
    private(set) var revision: UInt64
    private(set) var expectedDiskRevision: DiskRevision?
    private(set) var syncState: DocumentSyncState
    private(set) var conflict: DocumentConflict?
    private(set) var previousLocator: DocumentLocator?

    var filename: String { fileURL?.lastPathComponent ?? preferredFilename }
    var isBackedByFile: Bool { fileURL != nil }
    var isAutosavePaused: Bool { conflict != nil }
    var requiresExplicitRestore: Bool { fileURL == nil && previousLocator != nil }

    init(
        text: String = "",
        fileURL: URL? = nil,
        preferredFilename: String = Document.defaultFilename,
        id: DocumentID = DocumentID(),
        expectedDiskRevision: DiskRevision? = nil
    ) {
        self.id = id
        self.text = text
        self.fileURL = fileURL?.standardizedFileURL
        self.preferredFilename = preferredFilename.isEmpty
            ? Self.defaultFilename
            : preferredFilename
        self.expectedDiskRevision = expectedDiskRevision
        isDirty = fileURL == nil && !text.isEmpty
        revision = 0
        previousLocator = nil
        syncState = fileURL == nil
            ? .unbacked(previous: nil)
            : .clean(expectedDiskRevision ?? Self.syntheticRevision(for: text))
    }

    convenience init(contentsOf fileURL: URL, id: DocumentID = DocumentID()) throws {
        let standardizedURL = fileURL.standardizedFileURL
        let disk = try DocumentRevisionReader.documentSnapshot(at: standardizedURL)
        guard let text = String(data: disk.data, encoding: .utf8) else {
            throw ReadError.invalidUTF8(standardizedURL)
        }
        self.init(
            text: text,
            fileURL: standardizedURL,
            preferredFilename: standardizedURL.lastPathComponent,
            id: id,
            expectedDiskRevision: disk.revision
        )
    }

    func replaceText(with newText: String) {
        guard newText != text else { return }
        replaceTextFromEditor(with: newText)
    }

    /// NSTextView only reports `textDidChange` for a real character mutation,
    /// so the editor path can avoid a second whole-buffer equality scan.
    func replaceTextFromEditor(
        with newText: String,
        revisionAdvance: UInt64 = 1
    ) {
        text = newText
        revision &+= max(1, revisionAdvance)
        isDirty = true
        if conflict == nil {
            syncState = .dirty(base: expectedDiskRevision)
        }
    }

    func markUnbacked(previous locator: DocumentLocator? = nil) {
        guard fileURL != nil else { return }
        fileURL = nil
        expectedDiskRevision = nil
        conflict = nil
        previousLocator = locator
        revision &+= 1
        isDirty = true
        syncState = .unbacked(previous: locator)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            documentID: id,
            revision: revision,
            text: text,
            fileURL: fileURL,
            preferredFilename: preferredFilename,
            isDirty: isDirty,
            expectedDiskRevision: expectedDiskRevision,
            previousLocator: previousLocator
        )
    }

    func willWrite(_ snapshot: Snapshot) {
        syncState = .saving(
            base: snapshot.expectedDiskRevision,
            generation: BufferGeneration(
                bufferID: snapshot.documentID.rawValue,
                revision: snapshot.revision
            )
        )
    }

    func didWrite(_ snapshot: Snapshot, to fileURL: URL, revision diskRevision: DiskRevision) {
        self.fileURL = fileURL.standardizedFileURL
        preferredFilename = fileURL.lastPathComponent
        expectedDiskRevision = diskRevision
        conflict = nil
        previousLocator = nil
        if revision == snapshot.revision {
            isDirty = false
            syncState = .clean(diskRevision)
        } else {
            syncState = .dirty(base: diskRevision)
        }
    }

    func didFailWrite(_ snapshot: Snapshot) {
        guard conflict == nil else { return }
        syncState = .dirty(base: snapshot.expectedDiskRevision)
    }

    func didSkipEmptyUnbackedWrite(_ snapshot: Snapshot) {
        guard revision == snapshot.revision, fileURL == nil, text.isEmpty else { return }
        isDirty = false
        syncState = .unbacked(previous: nil)
    }

    func registerConflict(_ conflict: DocumentConflict) {
        let previous = self.conflict
        let candidates = (previous.map { [$0.external] + ($0.additionalExternalVersions ?? []) } ?? [])
            + (conflict.additionalExternalVersions ?? [])
            + [conflict.external]
        let versions = Self.deduplicatedConflictSides(candidates)
        let primaryDigest = Self.digest(for: conflict.external)
        let primary = versions.first { Self.digest(for: $0) == primaryDigest }
            ?? conflict.external
        let additional = versions.filter { Self.digest(for: $0) != primaryDigest }
        let merged = DocumentConflict(
            id: previous == nil ? conflict.id : UUID(),
            documentID: conflict.documentID,
            locator: conflict.locator,
            generation: BufferGeneration(bufferID: id.rawValue, revision: revision),
            clio: conflict.clio,
            external: primary,
            additionalExternalVersions: additional.isEmpty ? nil : additional
        )
        self.conflict = merged
        isDirty = true
        syncState = .conflicted(merged)
    }

    func applyExternal(source: String, revision diskRevision: DiskRevision) {
        text = source
        revision &+= 1
        isDirty = false
        expectedDiskRevision = diskRevision
        conflict = nil
        previousLocator = nil
        syncState = .clean(diskRevision)
    }

    func didMove(to newURL: URL, revision diskRevision: DiskRevision?) {
        fileURL = newURL.standardizedFileURL
        preferredFilename = newURL.lastPathComponent
        expectedDiskRevision = diskRevision
        conflict = nil
        previousLocator = nil
        if isDirty {
            syncState = .dirty(base: diskRevision)
        } else if let diskRevision {
            syncState = .clean(diskRevision)
        } else {
            syncState = .dirty(base: nil)
        }
    }

    /// Retargets a buffer after an outside rename while retaining its original
    /// disk base. Workspace reconciliation decides whether the bytes at the
    /// new path are a clean reload or a conflict.
    func prepareForExternalMove(to newURL: URL) {
        fileURL = newURL.standardizedFileURL
        preferredFilename = newURL.lastPathComponent
        previousLocator = nil
        revision &+= 1
        if let conflict {
            syncState = .conflicted(conflict)
        } else if isDirty {
            syncState = .dirty(base: expectedDiskRevision)
        }
    }

    private nonisolated static func syntheticRevision(for source: String) -> DiskRevision {
        let data = Data(source.utf8)
        return DiskRevision(
            modificationDate: .distantPast,
            byteCount: Int64(data.count),
            contentDigest: DocumentRevisionReader.digest(data)
        )
    }

    private nonisolated static func digest(for side: ConflictSide) -> String {
        side.revision?.contentDigest ?? DocumentRevisionReader.digest(side.data)
    }

    private nonisolated static func deduplicatedConflictSides(
        _ sides: [ConflictSide]
    ) -> [ConflictSide] {
        var orderedDigests: [String] = []
        var merged: [String: ConflictSide] = [:]

        for side in sides {
            let digest = digest(for: side)
            guard let prior = merged[digest] else {
                orderedDigests.append(digest)
                merged[digest] = side
                continue
            }
            let retained = Array(Set(prior.retainedURLs + side.retainedURLs))
            merged[digest] = ConflictSide(
                modificationDate: side.modificationDate,
                revision: side.revision ?? prior.revision,
                data: side.data,
                retainedURLs: retained
            )
        }
        return orderedDigests.compactMap { merged[$0] }
    }
}
