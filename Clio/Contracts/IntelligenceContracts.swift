import Foundation

/// Wire contracts for TypeSafe's System One endpoint.
///
/// Clio sends a `state` and a map of typed questions, and gets one typed answer
/// per question back. Nothing here performs I/O: the request builders and the
/// answer readers are pure so the intent and structure passes can be tested
/// against recorded payloads without a network.
///
/// See https://docs.typesafe.ai/api for the endpoint this mirrors.

// MARK: - JSON

/// A JSON value. `state`, `instructions` and Choice/Score criteria all accept a
/// string, an object or an array, so the encoder needs a type that carries any
/// of them without losing the distinction between them.
enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Character count of the encoded text, used for budgeting a request
    /// against the model's context window before it is sent.
    var characterCount: Int {
        switch self {
        case .string(let value): return value.count
        case .number, .bool, .null: return 8
        case .array(let values): return values.reduce(2) { $0 + $1.characterCount + 1 }
        case .object(let values):
            return values.reduce(2) { $0 + $1.key.count + $1.value.characterCount + 4 }
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}

// MARK: - Questions

/// Clarifies what yes and no mean for a Noul question. Optional; the question's
/// own wording carries most of the meaning.
struct NoulCriteria: Encodable, Hashable, Sendable {
    let `true`: String
    let `false`: String

    init(true yes: String, false no: String) {
        self.true = yes
        self.false = no
    }
}

/// One typed judgment. The three cases mirror TypeSafe's three primitives:
/// Noul returns a probability, Choice selects one of a defined set, and Score
/// places the state along ordered levels.
enum TypeSafeQuestion: Encodable, Hashable, Sendable {
    case noul(instructions: JSONValue, criteria: NoulCriteria? = nil)
    case choice(instructions: JSONValue, criteria: [String: String])
    case score(instructions: JSONValue, criteria: [String])

    private enum CodingKeys: String, CodingKey {
        case type, instructions, criteria
    }

    var typeName: String {
        switch self {
        case .noul: return "noul"
        case .choice: return "choice"
        case .score: return "score"
        }
    }

    var instructions: JSONValue {
        switch self {
        case .noul(let instructions, _),
             .choice(let instructions, _),
             .score(let instructions, _):
            return instructions
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(typeName, forKey: .type)
        try container.encode(instructions, forKey: .instructions)
        switch self {
        case .noul(_, let criteria):
            try container.encodeIfPresent(criteria, forKey: .criteria)
        case .choice(_, let criteria):
            try container.encode(criteria, forKey: .criteria)
        case .score(_, let criteria):
            try container.encode(criteria, forKey: .criteria)
        }
    }

    /// Approximate encoded size, used to keep `state` plus the longest question
    /// inside the model's per-question budget.
    var characterCount: Int {
        var total = instructions.characterCount + typeName.count
        switch self {
        case .noul(_, let criteria):
            total += (criteria?.true.count ?? 0) + (criteria?.false.count ?? 0)
        case .choice(_, let criteria):
            total += criteria.reduce(0) { $0 + $1.key.count + $1.value.count + 4 }
        case .score(_, let criteria):
            total += criteria.reduce(0) { $0 + $1.count + 3 }
        }
        return total
    }
}

// MARK: - Request

struct TypeSafeRequest: Encodable, Sendable {
    /// The pinned model. An alias moves when TypeSafe ships a release, which
    /// would shift answers under tuned thresholds without a change here, so
    /// Clio names a version and moves on its own schedule.
    static let defaultModel = "jev-1.13.0"

    let state: JSONValue
    let model: String
    let questions: [String: TypeSafeQuestion]

    init(state: JSONValue, questions: [String: TypeSafeQuestion], model: String = defaultModel) {
        self.state = state
        self.model = model
        self.questions = questions
    }
}

/// The published context window for `jev-1.13.0`: 64k tokens for the state plus
/// every question, and 32k for the state plus the single longest question.
/// Clio budgets in characters because it cannot tokenize, using a deliberately
/// pessimistic characters-per-token ratio so the guard trips before the API
/// does.
enum TypeSafeBudget {
    static let charactersPerToken = 3.0
    static let combinedTokenLimit = 64_000
    static let stateTokenLimit = 32_000

    static var combinedCharacterLimit: Int { Int(Double(combinedTokenLimit) * charactersPerToken) }
    static var stateCharacterLimit: Int { Int(Double(stateTokenLimit) * charactersPerToken) }

    /// Returns nil when the request fits, or the reason it does not.
    static func overflow(for request: TypeSafeRequest) -> String? {
        let state = request.state.characterCount
        let questions = request.questions.values
        let combined = state + questions.reduce(0) { $0 + $1.characterCount }
        if combined > combinedCharacterLimit {
            return "This request is too large for one evaluation."
        }
        let longest = questions.map(\.characterCount).max() ?? 0
        if state + longest > stateCharacterLimit {
            return "This document is too long to evaluate in one request."
        }
        return nil
    }
}

// MARK: - Answers

struct TypeSafeChoiceAnswer: Decodable, Hashable, Sendable {
    let choice: String
    let probabilities: [String: Double]
    let confidence: Double

    /// The probability of the option that was actually selected.
    var probability: Double { probabilities[choice] ?? 0 }
}

struct TypeSafeScoreAnswer: Decodable, Hashable, Sendable {
    let score: Double
    let legend: [String: String]
    let probabilities: [String: Double]
    let confidence: Double
}

enum TypeSafeAnswer: Decodable, Hashable, Sendable {
    case noul(Double)
    case choice(TypeSafeChoiceAnswer)
    case score(TypeSafeScoreAnswer)

    private enum CodingKeys: String, CodingKey {
        case type, noul
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "noul":
            self = .noul(try container.decode(Double.self, forKey: .noul))
        case "choice":
            self = .choice(try TypeSafeChoiceAnswer(from: decoder))
        case "score":
            self = .score(try TypeSafeScoreAnswer(from: decoder))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown answer type \(other)"
            )
        }
    }

    var noulValue: Double? {
        guard case .noul(let value) = self else { return nil }
        return value
    }

    var choiceValue: TypeSafeChoiceAnswer? {
        guard case .choice(let value) = self else { return nil }
        return value
    }

    var scoreValue: TypeSafeScoreAnswer? {
        guard case .score(let value) = self else { return nil }
        return value
    }
}

struct TypeSafeUsage: Decodable, Hashable, Sendable {
    let inputTokens: Int
    let outputTokens: Int

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

struct TypeSafeResponse: Decodable, Sendable {
    let model: String
    let answers: [String: TypeSafeAnswer]
    let usage: TypeSafeUsage

    subscript(id: String) -> TypeSafeAnswer? { answers[id] }
}

// MARK: - Errors

enum TypeSafeError: LocalizedError, Equatable {
    /// The feature is switched off in Settings. Clio never reaches the network
    /// in this state, and callers fall back to their local behaviour.
    case disabled
    case missingAPIKey
    case unauthorized
    case requestTooLarge(String)
    case invalidRequest(String)
    case rateLimited(retryAfter: TimeInterval?)
    case overloaded
    case server(status: Int)
    case transport(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Assisted commands are off. Turn them on in Settings."
        case .missingAPIKey:
            return "Add a TypeSafe API key in Settings to use assisted commands."
        case .unauthorized:
            return "The TypeSafe API key was rejected. Check it in Settings."
        case .requestTooLarge(let reason):
            return reason
        case .invalidRequest(let reason):
            return reason
        case .rateLimited:
            return "TypeSafe is rate limiting this key. Try again shortly."
        case .overloaded:
            return "TypeSafe is busy. Try again shortly."
        case .server(let status):
            return "TypeSafe returned an unexpected response (\(status))."
        case .transport:
            return "Clio could not reach TypeSafe. Check your connection."
        case .malformedResponse:
            return "TypeSafe returned a response Clio could not read."
        }
    }

    /// Whether a retry with backoff is worth attempting.
    var isTransient: Bool {
        switch self {
        case .rateLimited, .overloaded, .transport:
            return true
        case .server(let status):
            return status >= 500
        default:
            return false
        }
    }
}
