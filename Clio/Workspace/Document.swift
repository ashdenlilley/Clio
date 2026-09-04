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
        let disk = try DocumentRevisionReader.snapshot(at: standardizedURL)
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
        text = newText
        revision &+= 1
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
            expectedDiskRevision: expectedDiskRevision
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
        self.conflict = conflict
        isDirty = true
        syncState = .conflicted(conflict)
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

    private nonisolated static func syntheticRevision(for source: String) -> DiskRevision {
        let data = Data(source.utf8)
        return DiskRevision(
            modificationDate: .distantPast,
            byteCount: Int64(data.count),
            contentDigest: DocumentRevisionReader.digest(data)
        )
    }
}
