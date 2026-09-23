import Foundation
import Observation

/// Owns Clio's one outbound network capability.
///
/// Clio is a local-first editor, and every other part of it works with no
/// network at all. Assisted commands and paste formatting are the exception, so
/// they are off until the writer turns them on and are gated in exactly one
/// place: `evaluate(_:)` refuses before a request is built whenever the feature
/// is off or no key is stored. Callers treat a nil result as "carry on
/// locally", which is also what they do offline.
@MainActor
@Observable
final class IntelligenceService {
    private enum Keys {
        static let enabled = "intelligence.enabled"
        static let formatPastes = "intelligence.formatPastes"
    }

    /// The master switch. Off on first launch and after an upgrade, so an
    /// existing install never starts making requests because of an update.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Keys.enabled)
            if isEnabled {
                refreshKeyStatus()
            } else {
                lastError = nil
            }
        }
    }

    /// Whether a long unstructured paste may be offered as formatted Markdown.
    /// Separate from the master switch because it sends pasted text, while
    /// assisted commands send only what was typed into the command bar.
    var formatsPastes: Bool {
        didSet {
            guard formatsPastes != oldValue else { return }
            defaults.set(formatsPastes, forKey: Keys.formatPastes)
        }
    }

    /// Whether the stored key has been checked against the API, so Settings
    /// can tell "no key" apart from "a key that will not work".
    enum KeyVerification: Equatable {
        case unchecked
        case checking
        case valid
        case invalid(String)
    }

    private(set) var hasAPIKey: Bool
    private(set) var keyVerification = KeyVerification.unchecked
    private(set) var lastError: String?
    private(set) var isEvaluating = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var client = TypeSafeClient()
    @ObservationIgnored private let loadAPIKey: @Sendable () -> String?
    /// Writes the key, or removes it when passed nil. Returns whether the store
    /// accepted the change. Injected so tests never touch the real Keychain.
    @ObservationIgnored private let storeAPIKey: @Sendable (String?) -> Bool

    init(
        defaults: UserDefaults,
        loadAPIKey: @escaping @Sendable () -> String? = { TypeSafeKeychain.load() },
        storeAPIKey: @escaping @Sendable (String?) -> Bool = { key in
            guard let key else { return TypeSafeKeychain.remove() }
            return TypeSafeKeychain.save(key)
        }
    ) {
        self.defaults = defaults
        self.loadAPIKey = loadAPIKey
        self.storeAPIKey = storeAPIKey
        self.isEnabled = defaults.bool(forKey: Keys.enabled)
        // Paste formatting defaults on, but only ever runs behind `isEnabled`.
        self.formatsPastes = defaults.object(forKey: Keys.formatPastes) as? Bool ?? true
        self.hasAPIKey = loadAPIKey() != nil
    }

    /// Re-reads whether a key is stored. The Keychain is locked while the
    /// machine is, so a read at launch can come back empty for a key that is
    /// really there; this lets the answer be corrected later rather than
    /// leaving the feature quietly dead for the session.
    func refreshKeyStatus() {
        hasAPIKey = loadAPIKey() != nil
        if !hasAPIKey { keyVerification = .unchecked }
    }

    /// Sends the smallest possible request to confirm the stored key works.
    ///
    /// Gated behind `isEnabled` like every other request, so checking a key is
    /// still something the writer opts into rather than something Settings does
    /// on its own.
    func verifyKey() async {
        guard isReady else {
            keyVerification = .invalid(
                TypeSafeError.missingAPIKey.errorDescription ?? "No key stored."
            )
            return
        }
        keyVerification = .checking
        let probe = TypeSafeRequest(
            state: .string("ping"),
            questions: ["reachable": .noul(instructions: .string("Is this text in English?"))]
        )
        do {
            _ = try await evaluate(probe)
            keyVerification = .valid
        } catch let error as TypeSafeError {
            keyVerification = .invalid(error.errorDescription ?? "The key could not be checked.")
        } catch {
            keyVerification = .invalid(error.localizedDescription)
        }
    }

    /// Whether a request could be made right now. Callers check this before
    /// doing any work to build one.
    var isReady: Bool { isEnabled && hasAPIKey }

    var statusDescription: String {
        if !isEnabled { return "Off. Clio makes no network requests." }
        if !hasAPIKey { return "No key stored. Add your own TypeSafe API key to finish setting this up." }
        switch keyVerification {
        case .checking: return "Checking the key…"
        case .valid: return "Key checked and working."
        case .invalid(let reason): return reason
        case .unchecked: break
        }
        if let lastError { return lastError }
        return "Key stored. Ready."
    }

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return clearAPIKey() }
        let stored = storeAPIKey(trimmed)
        refreshKeyStatus()
        // A new key has not been checked, whatever the last one's result was.
        keyVerification = .unchecked
        lastError = stored ? nil : "Clio could not store the key in the Keychain."
    }

    func clearAPIKey() {
        _ = storeAPIKey(nil)
        hasAPIKey = false
        keyVerification = .unchecked
        lastError = nil
    }

    // MARK: - Evaluation

    func evaluate(_ request: TypeSafeRequest) async throws -> TypeSafeResponse {
        guard isEnabled else { throw TypeSafeError.disabled }
        guard let key = loadAPIKey() else {
            hasAPIKey = false
            throw TypeSafeError.missingAPIKey
        }
        isEvaluating = true
        defer { isEvaluating = false }
        do {
            let response = try await client.evaluate(request, apiKey: key)
            lastError = nil
            return response
        } catch let error as TypeSafeError {
            // A cancelled keystroke is not a failure worth reporting.
            lastError = error.errorDescription
            throw error
        }
    }

    // MARK: - Assisted commands

    /// Matches a natural-language palette request to a command, or returns nil
    /// when nothing matched well enough. Never throws: the palette's own
    /// substring filtering stays in charge, and a failure here is silent.
    func resolveCommand(
        for text: String,
        context: CommandIntentContext
    ) async -> CommandIntentResult? {
        guard isReady else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }
        let request = CommandIntentResolver.request(for: trimmed, context: context)
        guard let response = try? await evaluate(request) else { return nil }
        return CommandIntentResolver.resolve(response)
    }

    // MARK: - Structure recovery

    /// Rebuilds Markdown structure for a pasted block of plain text, or returns
    /// nil when the paste does not need it or the passes could not run.
    ///
    /// The two requests are sequential because the blocks classified by the
    /// second do not exist until the first has answered.
    func recoverStructure(from pasted: String) async -> String? {
        guard isReady, formatsPastes, StructureRecovery.shouldAttempt(pasted) else { return nil }

        let lines = StructureRecovery.lines(in: pasted)
        guard lines.count >= 3 else { return nil }

        let stitchRequest = StructureRecovery.stitchRequest(for: lines)
        guard let stitched = try? await evaluate(stitchRequest) else { return nil }
        let joins = StructureRecovery.joins(from: stitched, lineCount: lines.count)
        let blocks = StructureRecovery.merge(lines, joins: joins)

        guard !Task.isCancelled else { return nil }

        let classifyRequest = StructureRecovery.classifyRequest(for: blocks)
        guard let classified = try? await evaluate(classifyRequest) else { return nil }
        let judgments = StructureRecovery.judgments(from: classified, blockCount: blocks.count)

        let markdown = StructureRecovery.render(blocks, judgments: judgments)
        // Nothing was recovered if the result is the paste again.
        let normalized = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        return markdown == normalized ? nil : markdown
    }
}
