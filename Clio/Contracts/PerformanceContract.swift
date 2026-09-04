import Foundation
import os

enum PerformanceContract {
    static let guaranteedDocumentCount = 25_000
    static let guaranteedWorkspaceByteCount: Int64 = 2 * 1_024 * 1_024 * 1_024
    static let stressDocumentCount = 100_000
    static let stressWorkspaceByteCount: Int64 = 10 * 1_024 * 1_024 * 1_024

    static let fullMarkdownByteLimit = 10 * 1_024 * 1_024
    static let safeLargeFileByteLimit = 50 * 1_024 * 1_024

    static let quickOpenFirstResultP95 = Duration.milliseconds(50)
    static let quickOpenSettledP95 = Duration.milliseconds(100)
    static let warmSearchFirstResult = Duration.milliseconds(100)
    static let coldSearchFirstResult = Duration.milliseconds(250)
    static let searchSettled = Duration.milliseconds(500)
    static let freshIndex = Duration.seconds(60)
    static let externalChangeReflection = Duration.seconds(1)
}

enum PerformanceFixtureGenerator {
    private static let vocabulary = [
        "archive", "canvas", "clio", "draft", "focus", "history",
        "index", "margin", "notebook", "paragraph", "quiet", "revision",
        "search", "source", "workspace", "writing",
    ]

    /// Produces byte-for-byte repeatable UTF-8 fixtures without relying on the
    /// process-randomized Swift hash seed.
    static func document(
        index: Int,
        utf8ByteCount: Int,
        seed: UInt64 = 0x434C_494F
    ) -> String {
        guard utf8ByteCount > 0 else { return "" }

        var state = seed ^ UInt64(bitPattern: Int64(index))
        var bytes = Array("# Document \(index)\n\n".utf8.prefix(utf8ByteCount))
        bytes.reserveCapacity(utf8ByteCount)

        while bytes.count < utf8ByteCount {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let separator = state.isMultiple(of: 17) ? "\n\n" : " "
            let fragment = vocabulary[Int(state % UInt64(vocabulary.count))] + separator
            bytes.append(contentsOf: fragment.utf8.prefix(utf8ByteCount - bytes.count))
        }

        return String(decoding: bytes, as: UTF8.self)
    }

    /// Materializes a deterministic corpus for indexing and stress runs. Tests
    /// choose a small size; release benchmarks pass the contract constants.
    @discardableResult
    static func writeWorkspace(
        at rootURL: URL,
        documentCount: Int,
        totalUTF8ByteCount: Int64,
        seed: UInt64 = 0x434C_494F,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        guard documentCount > 0, totalUTF8ByteCount >= Int64(documentCount) else {
            return []
        }

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let baseSize = totalUTF8ByteCount / Int64(documentCount)
        let remainder = totalUTF8ByteCount % Int64(documentCount)
        var urls: [URL] = []
        urls.reserveCapacity(documentCount)

        for index in 0..<documentCount {
            let groupURL = rootURL.appendingPathComponent(
                String(format: "%03d", index / 1_000),
                isDirectory: true
            )
            try fileManager.createDirectory(at: groupURL, withIntermediateDirectories: true)
            let byteCount = baseSize + (Int64(index) < remainder ? 1 : 0)
            guard byteCount <= Int64(Int.max) else { throw CocoaError(.fileWriteOutOfSpace) }
            let fileURL = groupURL.appendingPathComponent(
                String(format: "document-%06d.md", index)
            )
            let source = document(
                index: index,
                utf8ByteCount: Int(byteCount),
                seed: seed
            )
            try Data(source.utf8).write(to: fileURL, options: .atomic)
            urls.append(fileURL)
        }

        return urls
    }
}

enum ClioSignpost {
    private static let signposter = OSSignposter(
        subsystem: "olympus.clio.mac",
        category: "Performance"
    )

    static func interval<T>(
        _ name: StaticString,
        operation: () throws -> T
    ) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try operation()
    }

    static func interval<T>(
        _ name: StaticString,
        operation: () async throws -> T
    ) async rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try await operation()
    }
}
