import Foundation

/// Produces a concise display projection without decoding or splitting both
/// complete conflict versions on the main actor. Exact conflict bytes remain
/// owned by `DocumentConflict` and are never truncated for recovery/resolution.
enum ConflictPreviewBuilder {
    static let maximumBytesPerSide = 256 * 1_024
    static let maximumDisplayedLineLength = 240

    static func preview(for conflict: DocumentConflict) async -> String {
        let local = conflict.clio.data
        let external = conflict.external.data
        let worker = Task.detached(priority: .utility) {
            makePreview(local: local, external: external)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated static func makePreview(local: Data, external: Data) -> String {
        let localWasTruncated = local.count > maximumBytesPerSide
        let externalWasTruncated = external.count > maximumBytesPerSide
        let localSource = String(
            decoding: local.prefix(maximumBytesPerSide),
            as: UTF8.self
        )
        let externalSource = String(
            decoding: external.prefix(maximumBytesPerSide),
            as: UTF8.self
        )
        let localLines = localSource.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        let externalLines = externalSource.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        let maximum = max(localLines.count, externalLines.count)
        var removed: [String] = []
        var added: [String] = []
        var changed = 0

        for index in 0..<maximum {
            if index.isMultiple(of: 1_024), Task.isCancelled { break }
            let localLine = index < localLines.count ? localLines[index] : nil
            let outsideLine = index < externalLines.count ? externalLines[index] : nil
            guard localLine != outsideLine else { continue }
            changed += 1
            if let localLine, removed.count < 3 {
                removed.append("− \(bounded(String(localLine)))")
            }
            if let outsideLine, added.count < 3 {
                added.append("+ \(bounded(String(outsideLine)))")
            }
        }

        guard changed > 0 || localWasTruncated || externalWasTruncated else {
            return "The text is identical."
        }
        var lines = removed + added
        if changed > 6 {
            lines.append("… \(changed - 6) more changed lines in preview")
        }
        if localWasTruncated || externalWasTruncated {
            lines.append("… additional changes may exist outside this bounded preview")
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func bounded(_ line: String) -> String {
        guard line.count > maximumDisplayedLineLength else { return line }
        return String(line.prefix(maximumDisplayedLineLength)) + "…"
    }
}
