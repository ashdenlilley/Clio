import Foundation
import Security

/// Keychain storage for the TypeSafe API key.
///
/// The key is a credential, so it never reaches `UserDefaults`, the bundle or a
/// log. It is stored for this device only and is not synchronised, matching how
/// `MCPKeychain` holds local MCP client tokens.
enum TypeSafeKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "olympus.clio.mac.typesafe",
         kSecAttrAccount as String: "api-key-v1",
         kSecAttrSynchronizable as String: false]
    }

    static func load() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              data.count < 8_192,
              let key = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return remove() }
        guard let data = trimmed.data(using: .utf8), data.count < 8_192 else { return false }
        var status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func remove() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static var hasKey: Bool { load() != nil }
}

/// Maps an HTTP response onto a `TypeSafeError`. Split out from the transport so
/// status handling can be tested without a server.
enum TypeSafeResponseMapper {
    static func error(forStatus status: Int, retryAfter: String?, body: Data) -> TypeSafeError? {
        switch status {
        case 200..<300:
            return nil
        case 401, 403:
            return .unauthorized
        case 413:
            return .requestTooLarge("This request is too large for one evaluation.")
        case 422:
            return .invalidRequest(detail(in: body)
                ?? "TypeSafe rejected the request as malformed.")
        case 429:
            return .rateLimited(retryAfter: retryAfter.flatMap(TimeInterval.init))
        case 529:
            return .overloaded
        default:
            return .server(status: status)
        }
    }

    /// TypeSafe describes a 422 in the body. Surface that text rather than a
    /// bare status, because it names the offending field.
    private static func detail(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        for key in ["detail", "message", "error"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}

/// Sends one evaluation request to TypeSafe and decodes the typed answers.
///
/// Retries only the transient statuses TypeSafe documents (429 and 529) plus
/// transport failures, with exponential backoff and the server's `retry-after`
/// when it sends one.
struct TypeSafeClient: Sendable {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    var endpoint: URL = TypeSafeClient.endpoint
    var session: URLSession = .shared
    var maximumAttempts = 3
    var timeout: TimeInterval = 20

    /// Injected so tests can drive backoff without waiting.
    var sleep: @Sendable (TimeInterval) async throws -> Void = {
        try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
    }

    func evaluate(_ request: TypeSafeRequest, apiKey: String) async throws -> TypeSafeResponse {
        if let overflow = TypeSafeBudget.overflow(for: request) {
            throw TypeSafeError.requestTooLarge(overflow)
        }
        let encoder = JSONEncoder()
        // Stable key order keeps identical questions byte-identical between
        // runs, which makes recorded payloads comparable in tests.
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(request)

        var attempt = 0
        var lastError: TypeSafeError = .transport("No attempt was made.")
        while attempt < max(1, maximumAttempts) {
            if attempt > 0 {
                try Task.checkCancellation()
                try await sleep(backoff(forAttempt: attempt, after: lastError))
            }
            attempt += 1
            do {
                return try await send(body: body, apiKey: apiKey)
            } catch let error as TypeSafeError where error.isTransient {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    private func send(body: Data, apiKey: String) async throws -> TypeSafeResponse {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Answers are small and always fresh; never serve one from a cache.
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TypeSafeError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TypeSafeError.malformedResponse
        }
        if let error = TypeSafeResponseMapper.error(
            forStatus: http.statusCode,
            retryAfter: http.value(forHTTPHeaderField: "retry-after"),
            body: data
        ) {
            throw error
        }
        do {
            return try JSONDecoder().decode(TypeSafeResponse.self, from: data)
        } catch {
            throw TypeSafeError.malformedResponse
        }
    }

    func backoff(forAttempt attempt: Int, after error: TypeSafeError) -> TimeInterval {
        if case .rateLimited(let retryAfter) = error, let retryAfter {
            return min(max(retryAfter, 0), 10)
        }
        return min(pow(2, Double(attempt - 1)) * 0.5, 8)
    }
}

/// Where the TypeSafe API key is read from and written to.
///
/// Real launches use the Keychain. UI tests substitute an in-memory store so a
/// run does not depend on, or disturb, the key belonging to whoever is running
/// it — the same isolation the launch configuration already gives defaults, the
/// workspace and the search index.
struct IntelligenceKeyStore: Sendable {
    var load: @Sendable () -> String?
    var store: @Sendable (String?) -> Bool

    static let keychain = IntelligenceKeyStore(
        load: { TypeSafeKeychain.load() },
        store: { key in
            guard let key else { return TypeSafeKeychain.remove() }
            return TypeSafeKeychain.save(key)
        }
    )

    /// Keeps a key only for the lifetime of the process.
    static func inMemory(_ initial: String? = nil) -> IntelligenceKeyStore {
        let box = Box(initial)
        return IntelligenceKeyStore(load: { box.value }, store: { box.value = $0; return true })
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        init(_ value: String?) { stored = value }
        var value: String? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
