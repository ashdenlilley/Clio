import Foundation

/// Owns each editable buffer once, even when several windows or authorized
/// paths refer to the same physical file.
@MainActor
final class DocumentBufferRegistry: DocumentBufferRegistering {
    private var documents: [DocumentID: Document] = [:]
    private var identities: [PhysicalFileIdentity: DocumentID] = [:]
    private var locators: [DocumentLocator: DocumentID] = [:]
    private var autosavers: [DocumentID: Autosaver] = [:]

    func open(_ fileURL: URL, in workspace: Workspace) throws -> Document {
        let standardizedURL = fileURL.standardizedFileURL
        let locator = try workspace.locator(for: standardizedURL)
        let identity = PhysicalFileIdentity.authorizedFile(at: standardizedURL)

        if let existing = document(for: identity, locator: locator) {
            updateAliases(
                for: existing.id,
                identity: identity,
                locator: locator
            )
            return existing
        }

        let id = documentID(for: identity, locator: locator)
        let document = try Document(contentsOf: standardizedURL, id: id)
        documents[id] = document
        return document
    }

    func register(_ document: Document, in workspace: Workspace) {
        documents[document.id] = document
        guard let fileURL = document.fileURL,
              let locator = try? workspace.locator(for: fileURL) else { return }
        updateAliases(
            for: document.id,
            identity: .authorizedFile(at: fileURL),
            locator: locator
        )
    }

    func document(at fileURL: URL, in workspace: Workspace) -> Document? {
        let standardizedURL = fileURL.standardizedFileURL
        let identity = PhysicalFileIdentity.authorizedFile(at: standardizedURL)
        if let id = identities[identity], let document = documents[id] {
            return document
        }
        guard let locator = try? workspace.locator(for: standardizedURL),
              let id = locators[locator] else { return nil }
        return documents[id]
    }

    func document(withID id: DocumentID) -> Document? { documents[id] }

    var openDocuments: [Document] { Array(documents.values) }

    func autosaver(for document: Document, in workspace: Workspace) -> Autosaver {
        if let autosaver = autosavers[document.id] { return autosaver }
        let autosaver = Autosaver(workspace: workspace, registry: self)
        autosavers[document.id] = autosaver
        return autosaver
    }

    func replaceAutosaver(for document: Document, in workspace: Workspace) -> Autosaver {
        autosavers[document.id]?.cancel()
        let autosaver = Autosaver(workspace: workspace, registry: self)
        autosavers[document.id] = autosaver
        return autosaver
    }

    func documentID(
        for identity: PhysicalFileIdentity,
        locator: DocumentLocator
    ) -> DocumentID {
        if let id = identities[identity] ?? locators[locator] {
            identities[identity] = id
            locators[locator] = id
            return id
        }
        let id = DocumentID()
        identities[identity] = id
        locators[locator] = id
        return id
    }

    func updateAliases(
        for documentID: DocumentID,
        identity: PhysicalFileIdentity,
        locator: DocumentLocator
    ) {
        identities[identity] = documentID
        locators[locator] = documentID
    }

    func updateAliases(for document: Document, in workspace: Workspace) {
        identities = identities.filter { $0.value != document.id }
        register(document, in: workspace)
    }

    func removeLocator(_ locator: DocumentLocator, for documentID: DocumentID) {
        if locators[locator] == documentID {
            locators.removeValue(forKey: locator)
        }
    }

    func detach(_ documentID: DocumentID, from locator: DocumentLocator) {
        removeLocator(locator, for: documentID)
        identities = identities.filter { $0.value != documentID }
    }

    private func document(
        for identity: PhysicalFileIdentity,
        locator: DocumentLocator
    ) -> Document? {
        if let id = identities[identity], let document = documents[id] {
            return document
        }
        if let id = locators[locator], let document = documents[id] {
            return document
        }
        return nil
    }
}
