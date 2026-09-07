import CryptoKit
import Foundation

/// Transport-independent policy. No listener is started by this module.
/// All authority changes are native-app operations, never MCP tools.
enum MCPAccessError: Error, Equatable {
    case disabled, unauthorized, forbiddenOrigin, invalidHost, oversizedRequest
    case invalidRequest, outsideWorkspace, staleRevision, invalidRange
    case retryConflict, retryCapacity, approvalRequired, expiredApproval
}

struct MCPLoopbackPolicy {
    static let maximumBodyBytes = 1_048_576
    let port: UInt16

    /// Called on parsed, duplicate-free HTTP headers before JSON decoding.
    /// Browser clients are not supported initially: an Origin is always rejected.
    func validate(host: String, origin: String?, bodyByteCount: Int) throws {
        guard port != 0,
              host == "127.0.0.1:\(port)" else { throw MCPAccessError.invalidHost }
        guard origin == nil else { throw MCPAccessError.forbiddenOrigin }
        guard bodyByteCount >= 0, bodyByteCount <= Self.maximumBodyBytes else {
            throw MCPAccessError.oversizedRequest
        }
    }
}

/// This token is process-local and cannot be supplied as a JSON argument.
struct MCPClientGrant: Equatable {
    let id: UUID
    let workspaceIDs: Set<WorkspaceID>
    fileprivate let epoch: UUID
}

@MainActor
final class MCPAccessController {
    private struct Client {
        let name: String
        let digest: Data
        let workspaces: Set<WorkspaceID>
    }

    private var clients: [UUID: Client] = [:]
    private var epoch = UUID()
    private(set) var isEnabled = false

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        // Pause/resume invalidates outstanding requests, not just new requests.
        epoch = UUID()
    }

    /// UI must approve the named client and exact workspace set before calling.
    /// Persist the random token in Keychain, never in defaults or document files.
    func authorizeClient(name: String, token: Data, workspaces: Set<WorkspaceID>, id: UUID = UUID()) throws -> UUID {
        guard token.count == 32, !workspaces.isEmpty,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 128, clients.count < 32, clients[id] == nil,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MCPAccessError.invalidRequest
        }
        let digest = Data(SHA256.hash(data: token))
        guard !clients.values.contains(where: { $0.digest == digest }) else {
            throw MCPAccessError.invalidRequest
        }
        clients[id] = Client(name: name, digest: digest, workspaces: workspaces)
        return id
    }

    func authenticate(token: Data) throws -> MCPClientGrant {
        guard isEnabled else { throw MCPAccessError.disabled }
        guard token.count == 32 else { throw MCPAccessError.unauthorized }
        let digest = Data(SHA256.hash(data: token))
        guard let entry = clients.first(where: { Self.constantTimeEqual($0.value.digest, digest) }) else {
            throw MCPAccessError.unauthorized
        }
        return MCPClientGrant(id: entry.key, workspaceIDs: entry.value.workspaces, epoch: epoch)
    }

    /// Recheck after EVERY await and directly before observing/mutating a buffer.
    func validate(_ grant: MCPClientGrant, workspaceID: WorkspaceID) throws {
        guard isEnabled else { throw MCPAccessError.disabled }
        guard grant.epoch == epoch, let client = clients[grant.id] else {
            throw MCPAccessError.unauthorized
        }
        guard client.workspaces.contains(workspaceID), grant.workspaceIDs.contains(workspaceID) else {
            throw MCPAccessError.outsideWorkspace
        }
    }

    func revoke(_ clientID: UUID) { clients.removeValue(forKey: clientID) }

    func stop() {
        isEnabled = false
        epoch = UUID()
        clients.removeAll()
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

struct MCPRevision: Codable, Equatable {
    // Incarnation prevents a revision counter from being reused after reopening.
    let incarnation: UUID
    let documentID: DocumentID
    let revision: UInt64
}

struct MCPTextReplacement: Codable, Equatable {
    let location: Int
    let length: Int
    let text: String

    /// Produces a candidate only. The editor/undo adapter must commit it without
    /// a suspension after checking its revision and settled live-buffer state.
    func applying(to source: String) throws -> String {
        let count = source.utf16.count
        guard location >= 0, length >= 0, location <= count, length <= count - location,
              text.utf8.count <= MCPLoopbackPolicy.maximumBodyBytes else {
            throw MCPAccessError.invalidRange
        }
        let nsRange = NSRange(location: location, length: length)
        // Reject partial surrogate pairs and partial composed characters.
        guard let range = Range(nsRange, in: source),
              (range.lowerBound == source.endIndex || source.indices.contains(range.lowerBound)),
              (range.upperBound == source.endIndex || source.indices.contains(range.upperBound)) else {
            throw MCPAccessError.invalidRange
        }
        let removedBytes = source[range].utf8.count
        guard source.utf8.count - removedBytes <= MCPLoopbackPolicy.maximumBodyBytes - text.utf8.count else {
            throw MCPAccessError.oversizedRequest
        }
        return source.replacingCharacters(in: range, with: text)
    }
}

/// Canonical path defense in depth; filesystem operations must still use the
/// authorized Workspace API and revalidate at the operation's commit boundary.
enum MCPWorkspaceBoundary {
    static func validate(_ file: URL, beneath root: URL) throws {
        guard file.isFileURL, root.isFileURL else { throw MCPAccessError.outsideWorkspace }
        let base = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let target = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard target.count > base.count, Array(target.prefix(base.count)) == base else {
            throw MCPAccessError.outsideWorkspace
        }
    }
}

/// Per-client retry ledger. Never evict successful mutations within a live
/// session: at capacity, fail closed and require a new session. Otherwise an old
/// retry could be silently reapplied. Session lifetime is owned by transport.
@MainActor
final class MCPMutationLedger {
    enum Reservation: Equatable { case execute, pending, completed(Data) }
    private struct Key: Hashable { let client: UUID; let request: UUID }
    private struct Entry { let digest: Data; var result: Data? }
    private var entries: [Key: Entry] = [:]
    private let capacity: Int
    private var resultBytes = 0
    private let maximumResultBytes = 4 * 1_048_576

    init(capacity: Int = 256) { self.capacity = max(1, capacity) }

    func reserve(client: UUID, request: UUID, canonicalArguments: Data) throws -> Reservation {
        guard canonicalArguments.count <= MCPLoopbackPolicy.maximumBodyBytes else {
            throw MCPAccessError.oversizedRequest
        }
        let key = Key(client: client, request: request)
        let digest = Data(SHA256.hash(data: canonicalArguments))
        if let entry = entries[key] {
            guard entry.digest == digest else { throw MCPAccessError.retryConflict }
            return entry.result.map(Reservation.completed) ?? .pending
        }
        guard entries.count < capacity,
              resultBytes <= maximumResultBytes - 16_384 else { throw MCPAccessError.retryCapacity }
        entries[key] = Entry(digest: digest)
        // Reserve bounded result space before any side effect can occur.
        resultBytes += 16_384
        return .execute
    }

    /// Complete with either success OR terminal failure, never remove after a
    /// potentially committed side effect. Lost responses remain replayable.
    func complete(client: UUID, request: UUID, result: Data) throws {
        let key = Key(client: client, request: request)
        guard var entry = entries[key], entry.result == nil else { throw MCPAccessError.invalidRequest }
        guard result.count <= 16_384 else { throw MCPAccessError.oversizedRequest }
        entry.result = result
        entries[key] = entry
    }
}

/// Native-only one-shot deletion approval. A model cannot mint an approval by
/// embedding instructions in a document or submitting a tool argument.
@MainActor
final class MCPDeletionApprovals {
    private struct Approval {
        let client: UUID
        let revision: MCPRevision
        let expires: TimeInterval
    }
    private var approvals: [UUID: Approval] = [:]
    private let now: () -> TimeInterval

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// Only the native confirmation callback may call this method. The tool
    /// router must never expose it. Approval is still followed by a scope check.
    func recordNativeConfirmation(client: UUID, revision: MCPRevision) throws -> UUID {
        let time = now()
        approvals = approvals.filter { $0.value.expires > time }
        guard approvals.count < 32 else { throw MCPAccessError.invalidRequest }
        let id = UUID()
        approvals[id] = Approval(client: client, revision: revision, expires: time + 60)
        return id
    }

    func consume(_ id: UUID, client: UUID, revision: MCPRevision) throws {
        guard let approval = approvals.removeValue(forKey: id) else { throw MCPAccessError.approvalRequired }
        guard approval.expires > now() else { throw MCPAccessError.expiredApproval }
        guard approval.client == client else { throw MCPAccessError.unauthorized }
        guard approval.revision == revision else { throw MCPAccessError.staleRevision }
    }
}
