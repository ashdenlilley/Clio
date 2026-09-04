import Foundation

actor RecoveryStore: RecoveryPersisting {
    nonisolated static let retention: TimeInterval = 7 * 24 * 60 * 60

    nonisolated static var preferredURL: URL {
        let physicalHomeURL = FileManager.default.homeDirectory(forUser: NSUserName())
            ?? FileManager.default.homeDirectoryForCurrentUser
        return physicalHomeURL
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Clio Recovery", isDirectory: true)
    }

    nonisolated let rootURL: URL
    nonisolated let isSecurityScopedAccessActive: Bool
    private let fileManager: FileManager
    private let writer: any AtomicFileWriting
    private let securityScopedURL: URL?

    init(
        rootURL: URL = RecoveryStore.preferredURL,
        fileManager: FileManager = .default,
        writer: any AtomicFileWriting = AtomicFileWriter(),
        accessSecurityScopedResource: Bool = false
    ) {
        let standardizedURL = rootURL.standardizedFileURL
        let didStart = accessSecurityScopedResource
            ? standardizedURL.startAccessingSecurityScopedResource()
            : false
        self.rootURL = standardizedURL
        self.fileManager = fileManager
        self.writer = writer
        securityScopedURL = didStart ? standardizedURL : nil
        isSecurityScopedAccessActive = didStart
    }

    deinit {
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }

    func preserve(
        documentID: DocumentID,
        filename: String,
        source: String,
        date: Date = Date()
    ) throws -> RecoveryReceipt {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let original = Workspace.safeFilename(from: filename)
        let extensionName = URL(fileURLWithPath: original).pathExtension
        let stem = URL(fileURLWithPath: original)
            .deletingPathExtension().lastPathComponent
        let stamp = Self.timestamp.string(from: date)
        let suffix = String(documentID.rawValue.uuidString.prefix(8))
        let recoveredName = extensionName.isEmpty
            ? "\(stem) — \(stamp) — \(suffix)"
            : "\(stem) — \(stamp) — \(suffix).\(extensionName)"
        let destinationURL = try availableURL(named: recoveredName)
        guard try writer.create(contents: Data(source.utf8), at: destinationURL) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fileManager.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: destinationURL.path
        )
        return RecoveryReceipt(
            documentID: documentID,
            recoveryURL: destinationURL,
            createdAt: date
        )
    }

    func prune(olderThan date: Date) throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        let urls = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for url in urls {
            let values = try url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
            ])
            guard values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < date else { continue }
            try fileManager.removeItem(at: url)
        }
    }

    func pruneExpired(now: Date = Date()) throws {
        try prune(olderThan: now.addingTimeInterval(-Self.retention))
    }

    private func availableURL(named name: String) throws -> URL {
        let candidate = rootURL.appendingPathComponent(name)
        if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        let fileURL = URL(fileURLWithPath: name)
        let ext = fileURL.pathExtension
        let stem = fileURL.deletingPathExtension().lastPathComponent
        for number in 2...10_000 {
            let variant = ext.isEmpty
                ? "\(stem) (\(number))"
                : "\(stem) (\(number)).\(ext)"
            let url = rootURL.appendingPathComponent(variant)
            if !fileManager.fileExists(atPath: url.path) { return url }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    private nonisolated static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter
    }()
}
