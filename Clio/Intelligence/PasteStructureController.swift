import AppKit

/// Reformats a pasted block of plain text once structure recovery answers.
///
/// The paste itself already happened: the writer sees their text land at once,
/// and this replaces it a moment later only if the passes found structure worth
/// applying. The replacement is its own undo group, so a single Command-Z takes
/// back the formatting and leaves the pasted text in place.
@MainActor
final class PasteStructureController {
    /// A paste is only reformatted while it is still the last thing that
    /// happened. Past this, the writer has moved on and a replacement under
    /// their caret would be an ambush.
    static let staleAfter: TimeInterval = 20

    private var task: Task<Void, Never>?
    private(set) var isRecovering = false

    deinit { task?.cancel() }

    func cancel() {
        task?.cancel()
        task = nil
        isRecovering = false
    }

    func recover(
        pasted: String,
        range: NSRange,
        in textView: NSTextView,
        using service: IntelligenceService
    ) {
        task?.cancel()
        guard service.isReady, service.formatsPastes,
              StructureRecovery.shouldAttempt(pasted) else { return }
        isRecovering = true
        let startedAt = Date()
        task = Task { @MainActor [weak self, weak textView] in
            defer { self?.isRecovering = false }
            guard let markdown = await service.recoverStructure(from: pasted),
                  !Task.isCancelled,
                  let textView,
                  Date().timeIntervalSince(startedAt) < Self.staleAfter else { return }
            self?.apply(markdown, replacing: range, original: pasted, in: textView)
        }
    }

    /// Replaces the pasted range, but only if it still holds exactly the text
    /// that was pasted. Anything else means the writer has edited since, and
    /// the recovered Markdown no longer describes what is there.
    private func apply(
        _ markdown: String,
        replacing range: NSRange,
        original: String,
        in textView: NSTextView
    ) {
        let text = textView.string as NSString
        guard NSMaxRange(range) <= text.length,
              text.substring(with: range) == original,
              textView.shouldChangeText(in: range, replacementString: markdown),
              let storage = textView.textStorage else { return }

        let undoManager = textView.undoManager
        let ownsGroup = undoManager?.groupingLevel == 0
        if ownsGroup { undoManager?.beginUndoGrouping() }
        storage.replaceCharacters(in: range, with: markdown)
        textView.didChangeText()
        textView.setSelectedRange(
            NSRange(location: range.location + (markdown as NSString).length, length: 0)
        )
        undoManager?.setActionName("Format Pasted Text")
        if ownsGroup { undoManager?.endUndoGrouping() }
    }
}
