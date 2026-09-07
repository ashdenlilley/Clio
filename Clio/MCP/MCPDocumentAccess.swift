import Foundation

struct MCPDocumentPage: Codable {
    let revision: MCPRevision
    let text: String
    let utf16Offset: Int
    let nextUTF16Offset: Int?
    let saveState: String
}

/// First integration layer: live, settled reads through the existing registry.
/// No network API, arbitrary-path opens or filesystem writes are introduced.
@MainActor
final class MCPDocumentAccess {
    private let access: MCPAccessController
    private let registry: DocumentBufferRegistry
    private struct Incarnation {
        weak var document: Document?
        let id: UUID
    }
    private var incarnations: [DocumentID: Incarnation] = [:]

    init(access: MCPAccessController, registry: DocumentBufferRegistry) {
        self.access = access
        self.registry = registry
    }

    func read(
        documentID: DocumentID, workspace: Workspace, grant: MCPClientGrant,
        offset: Int = 0, limit: Int = 16_384, expectedRevision: MCPRevision? = nil,
        authorizedUntitled: Bool = false
    ) async throws -> MCPDocumentPage {
        try access.validate(grant, workspaceID: workspace.id)
        try Task.checkCancellation()
        return try await registry.withSettledEditorEdits(for: documentID) {
            try Task.checkCancellation()
            try self.access.validate(grant, workspaceID: workspace.id)
            guard let document = self.registry.document(withID: documentID) else { throw MCPAccessError.outsideWorkspace }
            if let file = document.fileURL {
                try MCPWorkspaceBoundary.validate(file, beneath: workspace.rootURL)
                _ = try workspace.locator(for: file)
            } else if !authorizedUntitled { throw MCPAccessError.outsideWorkspace }
            let token = self.revision(for: document)
            if let expectedRevision, expectedRevision != token { throw MCPAccessError.staleRevision }
            // Further pages MUST be tied to a revision, otherwise concurrent
            // typing could silently concatenate portions of different documents.
            guard offset == 0 || expectedRevision != nil else { throw MCPAccessError.staleRevision }
            guard offset >= 0, limit > 0, limit <= 16_384 else { throw MCPAccessError.invalidRange }
            let source = document.text as NSString
            guard offset <= source.length else { throw MCPAccessError.invalidRange }
            var end = offset + min(limit, source.length - offset)
            // UTF-16 paging never splits a surrogate pair. It may split a
            // grapheme across pages; concatenating pages preserves exact bytes.
            if offset > 0, offset < source.length,
               Self.isLowSurrogate(source.character(at: offset)) {
                throw MCPAccessError.invalidRange
            }
            if end < source.length, Self.isLowSurrogate(source.character(at: end)) { end -= 1 }
            guard end > offset || offset == source.length else { throw MCPAccessError.invalidRange }
            return MCPDocumentPage(
                revision: token,
                text: source.substring(with: NSRange(location: offset, length: end - offset)),
                utf16Offset: offset,
                nextUTF16Offset: end < source.length ? end : nil,
                saveState: document.conflict != nil ? "conflict" : (document.isDirty ? "pending" : "saved")
            )
        }
    }

    func revision(for document: Document) -> MCPRevision {
        incarnations = incarnations.filter { $0.value.document != nil }
        if incarnations[document.id]?.document !== document {
            incarnations[document.id] = Incarnation(document: document, id: UUID())
        }
        return MCPRevision(incarnation: incarnations[document.id]!.id,
                           documentID: document.id, revision: document.revision)
    }

    private static func isLowSurrogate(_ value: unichar) -> Bool { (0xDC00...0xDFFF).contains(value) }
}
