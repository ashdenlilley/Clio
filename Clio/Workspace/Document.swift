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
                return "\(url.lastPathComponent) is not a UTF-8 text file."
            }
        }
    }

    struct Snapshot: Sendable, Equatable {
        let revision: UInt64
        let text: String
        let fileURL: URL?
        let preferredFilename: String
        let isDirty: Bool
    }

    nonisolated static let defaultFilename = "untitled.md"

    let id: UUID
    let preferredFilename: String

    private(set) var text: String
    private(set) var fileURL: URL?
    private(set) var isDirty: Bool
    private(set) var revision: UInt64

    var filename: String {
        fileURL?.lastPathComponent ?? preferredFilename
    }

    var isBackedByFile: Bool {
        fileURL != nil
    }

    init(
        text: String = "",
        fileURL: URL? = nil,
        preferredFilename: String = Document.defaultFilename,
        id: UUID = UUID()
    ) {
        self.id = id
        self.text = text
        self.fileURL = fileURL?.standardizedFileURL
        self.preferredFilename = preferredFilename.isEmpty
            ? Self.defaultFilename
            : preferredFilename
        isDirty = fileURL == nil && !text.isEmpty
        revision = 0
    }

    convenience init(contentsOf fileURL: URL) throws {
        let standardizedURL = fileURL.standardizedFileURL
        let data = try Data(contentsOf: standardizedURL)

        guard let text = String(data: data, encoding: .utf8) else {
            throw ReadError.invalidUTF8(standardizedURL)
        }

        self.init(
            text: text,
            fileURL: standardizedURL,
            preferredFilename: standardizedURL.lastPathComponent
        )
    }

    /// Replaces the exact plain-text buffer. Call `Autosaver.documentDidChange(_:)`
    /// after an edit so the new revision is persisted.
    func replaceText(with newText: String) {
        guard newText != text else { return }

        text = newText
        revision &+= 1
        isDirty = true
    }

    /// Leaves the buffer intact after an external deletion. Its next save will
    /// recreate the file at a collision-safe workspace URL.
    func markUnbacked() {
        guard fileURL != nil else { return }

        fileURL = nil
        revision &+= 1
        isDirty = !text.isEmpty
    }

    func snapshot() -> Snapshot {
        Snapshot(
            revision: revision,
            text: text,
            fileURL: fileURL,
            preferredFilename: preferredFilename,
            isDirty: isDirty
        )
    }

    func didWrite(_ snapshot: Snapshot, to fileURL: URL) {
        if self.fileURL == nil {
            self.fileURL = fileURL.standardizedFileURL
        }

        if revision == snapshot.revision {
            isDirty = false
        }
    }

    func didSkipEmptyUnbackedWrite(_ snapshot: Snapshot) {
        guard revision == snapshot.revision, fileURL == nil, text.isEmpty else {
            return
        }

        isDirty = false
    }
}
