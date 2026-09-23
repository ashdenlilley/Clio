import XCTest
@testable import Clio

/// Serves canned responses to the TypeSafe client and records what was sent, so
/// transport behaviour can be exercised without reaching the network.
final class StubTypeSafeProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
    }

    nonisolated(unsafe) static var replies: [Reply] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []

    static func reset() {
        replies = []
        requests = []
        bodies = []
    }

    static func enqueue(status: Int = 200, json: String, headers: [String: String] = [:]) {
        replies.append(Reply(status: status, body: Data(json.utf8), headers: headers))
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTypeSafeProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        // URLProtocol strips httpBody for streamed uploads; read the stream.
        if let body = request.httpBody {
            Self.bodies.append(body)
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            Self.bodies.append(data)
        }
        let reply = Self.replies.isEmpty
            ? Reply(status: 500, body: Data("{}".utf8))
            : Self.replies.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: reply.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private let choiceResponseJSON = """
{
  "model": "jev-1.13.0",
  "answers": {
    "command": {
      "type": "choice",
      "choice": "export",
      "probabilities": {"export": 0.88, "new": 0.08, "__none__": 0.04},
      "confidence": 0.81
    },
    "export_format": {
      "type": "choice",
      "choice": "docx",
      "probabilities": {"docx": 0.91, "pdf": 0.06, "html": 0.02, "txt": 0.01},
      "confidence": 0.89
    },
    "export_format_stated": {"type": "noul", "noul": 0.94}
  },
  "usage": {"input_tokens": 318, "output_tokens": 34}
}
"""

final class IntelligenceContractTests: XCTestCase {
    private func encoded(_ request: TypeSafeRequest) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testRequestEncodesTheShapeTheEndpointDocuments() throws {
        let request = TypeSafeRequest(
            state: .string("Help! My payouts have been failing for 3 days."),
            questions: [
                "is_urgent": .noul(
                    instructions: .string("Does this convey urgency?"),
                    criteria: NoulCriteria(
                        true: "Explicitly time-sensitive",
                        false: "No urgency expressed"
                    )
                ),
                "department": .choice(
                    instructions: .string("Which team should handle this?"),
                    criteria: ["billing": "Payments", "technical": "Bugs"]
                ),
                "frustration": .score(
                    instructions: .string("How frustrated is the customer?"),
                    criteria: ["Calm", "Frustrated", "Very angry"]
                ),
            ]
        )
        let object = try encoded(request)
        XCTAssertEqual(object["model"] as? String, "jev-1.13.0")
        XCTAssertEqual(object["state"] as? String, "Help! My payouts have been failing for 3 days.")

        let questions = try XCTUnwrap(object["questions"] as? [String: [String: Any]])
        XCTAssertEqual(questions["is_urgent"]?["type"] as? String, "noul")
        XCTAssertEqual(
            (questions["is_urgent"]?["criteria"] as? [String: String])?["true"],
            "Explicitly time-sensitive"
        )
        XCTAssertEqual(questions["department"]?["type"] as? String, "choice")
        XCTAssertNotNil(questions["department"]?["criteria"] as? [String: String])
        XCTAssertEqual(questions["frustration"]?["type"] as? String, "score")
        XCTAssertEqual(questions["frustration"]?["criteria"] as? [String], ["Calm", "Frustrated", "Very angry"])
    }

    func testNoulCriteriaIsOmittedWhenNotSupplied() throws {
        let request = TypeSafeRequest(
            state: .string("x"),
            questions: ["q": .noul(instructions: .string("Is it so?"))]
        )
        let questions = try XCTUnwrap(try encoded(request)["questions"] as? [String: [String: Any]])
        XCTAssertNil(questions["q"]?["criteria"])
    }

    func testStructuredStateEncodesNestedFields() throws {
        let context = CommandIntentContext(
            hasOpenDocument: true,
            documentExistsOnDisk: false,
            isFocusModeEnabled: true,
            isTypewriterEnabled: false,
            isSidebarVisible: true
        )
        let request = CommandIntentResolver.request(for: "save this as word", context: context)
        let object = try encoded(request)
        let state = try XCTUnwrap(object["state"] as? [String: Any])
        XCTAssertEqual(state["request"] as? String, "save this as word")
        let editor = try XCTUnwrap(state["editor"] as? [String: Any])
        XCTAssertEqual(editor["has_open_document"] as? Bool, true)
        XCTAssertEqual(editor["document_saved_to_disk"] as? Bool, false)
        XCTAssertEqual(editor.count, 5, "Only window state travels, never the document")
    }

    func testAnswersDecodeForEveryQuestionType() throws {
        let json = """
        {
          "model": "jev-1.13.0",
          "answers": {
            "is_urgent": {"type": "noul", "noul": 0.95},
            "department": {
              "type": "choice", "choice": "billing",
              "probabilities": {"billing": 0.88, "technical": 0.12},
              "confidence": 0.81
            },
            "frustration": {
              "type": "score", "score": 1.05,
              "legend": {"0": "Calm", "1": "Frustrated"},
              "probabilities": {"0": 0.05, "1": 0.95},
              "confidence": 0.92
            }
          },
          "usage": {"input_tokens": 296, "output_tokens": 20}
        }
        """
        let response = try JSONDecoder().decode(TypeSafeResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.model, "jev-1.13.0")
        XCTAssertEqual(response["is_urgent"]?.noulValue, 0.95)
        XCTAssertEqual(response["department"]?.choiceValue?.choice, "billing")
        XCTAssertEqual(response["department"]?.choiceValue?.probability ?? 0, 0.88, accuracy: 0.0001)
        XCTAssertEqual(response["frustration"]?.scoreValue?.score ?? 0, 1.05, accuracy: 0.0001)
        XCTAssertEqual(response.usage.inputTokens, 296)
    }

    func testBudgetRejectsAStateLargerThanTheContextWindow() {
        let oversized = String(repeating: "word ", count: 40_000)
        let request = TypeSafeRequest(
            state: .string(oversized),
            questions: ["q": .noul(instructions: .string("Is it long?"))]
        )
        XCTAssertNotNil(TypeSafeBudget.overflow(for: request))

        let modest = TypeSafeRequest(
            state: .string("a short paste"),
            questions: ["q": .noul(instructions: .string("Is it long?"))]
        )
        XCTAssertNil(TypeSafeBudget.overflow(for: modest))
    }

    func testStatusesMapOntoTheDocumentedErrors() {
        func error(_ status: Int, body: String = "{}", retryAfter: String? = nil) -> TypeSafeError? {
            TypeSafeResponseMapper.error(
                forStatus: status,
                retryAfter: retryAfter,
                body: Data(body.utf8)
            )
        }
        XCTAssertNil(error(200))
        XCTAssertEqual(error(401), .unauthorized)
        XCTAssertEqual(error(429, retryAfter: "3"), .rateLimited(retryAfter: 3))
        XCTAssertEqual(error(529), .overloaded)
        XCTAssertEqual(error(500), .server(status: 500))
        XCTAssertEqual(
            error(422, body: #"{"detail":"questions.q.criteria is required"}"#),
            .invalidRequest("questions.q.criteria is required")
        )
        XCTAssertTrue(TypeSafeError.overloaded.isTransient)
        XCTAssertFalse(TypeSafeError.unauthorized.isTransient)
    }
}

final class TypeSafeClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubTypeSafeProtocol.reset()
    }

    private func makeClient() -> TypeSafeClient {
        var client = TypeSafeClient()
        client.session = StubTypeSafeProtocol.makeSession()
        client.sleep = { _ in }
        return client
    }

    private var sampleRequest: TypeSafeRequest {
        TypeSafeRequest(
            state: .string("a request"),
            questions: ["command": .choice(
                instructions: .string("What?"),
                criteria: ["export": "out", "__none__": "nothing"]
            )]
        )
    }

    func testSendsBearerAuthorizationAndJSONBody() async throws {
        StubTypeSafeProtocol.enqueue(json: choiceResponseJSON)
        _ = try await makeClient().evaluate(sampleRequest, apiKey: "secret-key")

        let request = try XCTUnwrap(StubTypeSafeProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, TypeSafeClient.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(StubTypeSafeProtocol.bodies.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["state"] as? String, "a request")
    }

    func testRetriesTransientStatusesThenSucceeds() async throws {
        StubTypeSafeProtocol.enqueue(status: 429, json: "{}", headers: ["retry-after": "1"])
        StubTypeSafeProtocol.enqueue(status: 529, json: "{}")
        StubTypeSafeProtocol.enqueue(json: choiceResponseJSON)

        let response = try await makeClient().evaluate(sampleRequest, apiKey: "key")
        XCTAssertEqual(response["command"]?.choiceValue?.choice, "export")
        XCTAssertEqual(StubTypeSafeProtocol.requests.count, 3)
    }

    func testDoesNotRetryARejectedKey() async {
        StubTypeSafeProtocol.enqueue(status: 401, json: "{}")
        do {
            _ = try await makeClient().evaluate(sampleRequest, apiKey: "bad")
            XCTFail("A rejected key must surface rather than retry")
        } catch {
            XCTAssertEqual(error as? TypeSafeError, .unauthorized)
        }
        XCTAssertEqual(StubTypeSafeProtocol.requests.count, 1)
    }

    func testGivesUpAfterTheAttemptLimit() async {
        for _ in 0..<5 { StubTypeSafeProtocol.enqueue(status: 529, json: "{}") }
        do {
            _ = try await makeClient().evaluate(sampleRequest, apiKey: "key")
            XCTFail("Repeated overload must surface")
        } catch {
            XCTAssertEqual(error as? TypeSafeError, .overloaded)
        }
        XCTAssertEqual(StubTypeSafeProtocol.requests.count, 3)
    }

    func testBackoffHonoursRetryAfterAndOtherwiseGrows() {
        let client = TypeSafeClient()
        XCTAssertEqual(client.backoff(forAttempt: 1, after: .rateLimited(retryAfter: 4)), 4)
        XCTAssertEqual(client.backoff(forAttempt: 1, after: .overloaded), 0.5)
        XCTAssertEqual(client.backoff(forAttempt: 3, after: .overloaded), 2)
        XCTAssertLessThanOrEqual(client.backoff(forAttempt: 20, after: .overloaded), 8)
    }

    func testAnOversizedRequestNeverLeavesTheMachine() async {
        var client = makeClient()
        client.maximumAttempts = 1
        let request = TypeSafeRequest(
            state: .string(String(repeating: "word ", count: 40_000)),
            questions: ["q": .noul(instructions: .string("Long?"))]
        )
        do {
            _ = try await client.evaluate(request, apiKey: "key")
            XCTFail("The budget guard must trip before the request is sent")
        } catch {
            guard case .requestTooLarge = error as? TypeSafeError else {
                return XCTFail("Unexpected error \(error)")
            }
        }
        XCTAssertTrue(StubTypeSafeProtocol.requests.isEmpty)
    }
}

final class CommandIntentTests: XCTestCase {
    private func response(_ json: String) throws -> TypeSafeResponse {
        try JSONDecoder().decode(TypeSafeResponse.self, from: Data(json.utf8))
    }

    func testEveryPaletteCommandIsDescribedExactlyOnce() {
        let described = Set(CommandIntentSpec.commandCriteria.keys)
            .subtracting([CommandIntentSpec.noMatch])
        let palette = Set(ClioCommandDescriptor.all.map(\.command.rawValue))
        XCTAssertEqual(
            described,
            palette,
            "Every command the palette lists needs a description, and nothing else may be offered"
        )
        XCTAssertNotNil(
            CommandIntentSpec.commandCriteria[CommandIntentSpec.noMatch],
            "Without a no-match option the model must name a command for any input"
        )
    }

    func testExportFormatCriteriaMatchTheParsersAcceptedFormats() throws {
        XCTAssertEqual(
            Set(CommandIntentSpec.exportFormatCriteria.keys),
            Set(CommandIntentSpec.exportFormats)
        )
        // Every advertised format must survive the real parser.
        for format in CommandIntentSpec.exportFormats {
            let invocation = try ClioCommandParser.parse("/export \(format)")
            XCTAssertEqual(invocation.command, .export)
            XCTAssertEqual(invocation.arguments, [format])
        }
    }

    func testQuestionsCoverTheChoiceAndItsSpeculativeArgument() {
        let questions = CommandIntentResolver.questions()
        XCTAssertEqual(Set(questions.keys), [
            CommandIntentSpec.commandQuestionID,
            CommandIntentSpec.exportFormatQuestionID,
            CommandIntentSpec.exportFormatStatedQuestionID,
        ])
        guard case .choice(_, let criteria)? = questions[CommandIntentSpec.commandQuestionID] else {
            return XCTFail("The command question must be a choice")
        }
        XCTAssertEqual(criteria.count, ClioCommandDescriptor.all.count + 1)
    }

    func testFillsTheExportArgumentWhenTheRequestNamesAFormat() throws {
        let result = try XCTUnwrap(CommandIntentResolver.resolve(response(choiceResponseJSON)))
        XCTAssertEqual(result.invocation.command, .export)
        XCTAssertEqual(result.invocation.arguments, ["docx"])
        // Weakest link: the command's own probability, not the format's.
        XCTAssertEqual(result.confidence, 0.81, accuracy: 0.0001)
        XCTAssertEqual(result.ranked.first, .export)
    }

    func testOmitsTheArgumentWhenTheRequestLeavesTheFormatOpen() throws {
        let json = """
        {
          "model": "jev-1.13.0",
          "answers": {
            "command": {
              "type": "choice", "choice": "export",
              "probabilities": {"export": 0.79, "__none__": 0.21},
              "confidence": 0.74
            },
            "export_format": {
              "type": "choice", "choice": "pdf",
              "probabilities": {"pdf": 0.4, "docx": 0.3, "html": 0.2, "txt": 0.1},
              "confidence": 0.3
            },
            "export_format_stated": {"type": "noul", "noul": 0.11}
          },
          "usage": {"input_tokens": 300, "output_tokens": 20}
        }
        """
        let result = try XCTUnwrap(CommandIntentResolver.resolve(response(json)))
        XCTAssertEqual(result.invocation.command, .export)
        XCTAssertTrue(
            result.invocation.arguments.isEmpty,
            "With no format stated the export picker decides, not a guess"
        )
    }

    func testListsOnlyPlausibleAlternativesUnderTheTopMatch() throws {
        let json = """
        {
          "model": "jev-1.13.0",
          "answers": {
            "command": {
              "type": "choice", "choice": "search",
              "probabilities": {
                "search": 0.71, "open": 0.19, "new": 0.08,
                "rename": 0.01, "delete": 0.005, "reveal": 0.0,
                "folder": 0.0, "export": 0.0, "focus": 0.0,
                "typewriter": 0.0, "sidebar": 0.0, "settings": 0.0,
                "__none__": 0.005
              },
              "confidence": 0.77
            },
            "export_format": {
              "type": "choice", "choice": "pdf",
              "probabilities": {"pdf": 1.0, "docx": 0.0, "html": 0.0, "txt": 0.0},
              "confidence": 1.0
            },
            "export_format_stated": {"type": "noul", "noul": 0.01}
          },
          "usage": {"input_tokens": 240, "output_tokens": 18}
        }
        """
        let result = try XCTUnwrap(CommandIntentResolver.resolve(try response(json)))
        XCTAssertEqual(result.ranked, [.search, .open, .new])
        XCTAssertFalse(
            result.ranked.contains(.settings),
            "Commands the model ruled out are noise, not second guesses"
        )
    }

    func testReturnsNothingWhenNoCommandFits() throws {
        let json = """
        {
          "model": "jev-1.13.0",
          "answers": {
            "command": {
              "type": "choice", "choice": "__none__",
              "probabilities": {"__none__": 0.82, "new": 0.18},
              "confidence": 0.79
            },
            "export_format": {
              "type": "choice", "choice": "pdf",
              "probabilities": {"pdf": 1.0, "docx": 0.0, "html": 0.0, "txt": 0.0},
              "confidence": 1.0
            },
            "export_format_stated": {"type": "noul", "noul": 0.02}
          },
          "usage": {"input_tokens": 200, "output_tokens": 10}
        }
        """
        XCTAssertNil(CommandIntentResolver.resolve(try response(json)))
    }

    func testReturnsNothingWhenTheFieldIsTooScattered() throws {
        let json = """
        {
          "model": "jev-1.13.0",
          "answers": {
            "command": {
              "type": "choice", "choice": "rename",
              "probabilities": {"rename": 0.29, "delete": 0.26, "new": 0.25, "open": 0.2},
              "confidence": 0.31
            },
            "export_format": {
              "type": "choice", "choice": "pdf",
              "probabilities": {"pdf": 1.0, "docx": 0.0, "html": 0.0, "txt": 0.0},
              "confidence": 1.0
            },
            "export_format_stated": {"type": "noul", "noul": 0.1}
          },
          "usage": {"input_tokens": 200, "output_tokens": 10}
        }
        """
        XCTAssertNil(
            CommandIntentResolver.resolve(try response(json)),
            "A command that merely leads a scattered field must not be offered"
        )
    }
}

final class StructureRecoveryTests: XCTestCase {
    /// A memo in the state this feature exists for: hard wrapped mid-sentence,
    /// with every marker stripped out.
    private let memo = """
    Migration to the new build system

    Hi everyone, quick heads up about the build system migration that is
    happening next week. We have been running the new pipeline in shadow
    mode for three weeks and the results look solid, so it is time to
    make the switch for real.

    Things to do before Monday

    Update your local toolchain to version 2.4 or later
    Delete the old build cache directory
    Run the doctor script and fix anything it flags
    """

    func testSkipsPastesThatAlreadyCarryTheirMarkup() {
        let markdown = """
        # A title that survived

        - first item in a list
        - second item in a list
        - third item in a list

        Some prose underneath it that runs on for a while so the paste is long
        enough to clear the minimum length gate comfortably and then some more.
        """
        XCTAssertFalse(
            StructureRecovery.shouldAttempt(markdown),
            "Markers are direct evidence; code reads them rather than paying for a request"
        )
        XCTAssertTrue(StructureRecovery.shouldAttempt(memo))
    }

    func testSkipsShortAndSingleLinePastes() {
        XCTAssertFalse(StructureRecovery.shouldAttempt("a quick note"))
        XCTAssertFalse(StructureRecovery.shouldAttempt(String(repeating: "one long line ", count: 40)))
    }

    func testReadsBlankLinesAsBlockSeparatorsInCode() {
        let lines = StructureRecovery.lines(in: memo)
        XCTAssertEqual(lines.first?.text, "Migration to the new build system")
        XCTAssertFalse(lines[0].precededByGap, "A leading blank is not a separator")
        XCTAssertTrue(lines[1].precededByGap)
        XCTAssertFalse(lines[2].precededByGap)
        XCTAssertFalse(lines.contains { $0.text.isEmpty })
    }

    func testStitchAsksOnlyAboutPairsThatABlankLineDidNotAlreadySeparate() {
        let lines = StructureRecovery.lines(in: memo)
        let request = StructureRecovery.stitchRequest(for: lines)
        let expected = lines.indices.filter { $0 > 0 && !lines[$0].precededByGap }.count
        XCTAssertEqual(request.questions.count, expected)
        XCTAssertFalse(request.questions.keys.contains(StructureRecovery.lineID(0)))
    }

    func testMergeBarIsHigherAfterATerminatedSentence() {
        XCTAssertTrue(StructureRecovery.endsTerminally("so it is time to switch."))
        XCTAssertFalse(StructureRecovery.endsTerminally("the results look solid, so it is"))

        let lines = [
            StructureRecovery.Line(text: "a sentence that trails off and", precededByGap: false),
            StructureRecovery.Line(text: "carries on here.", precededByGap: false),
            StructureRecovery.Line(text: "A new thought entirely.", precededByGap: false),
        ]
        // 0.3 clears the dangling bar (0.2) but not the terminal bar (0.5).
        let blocks = StructureRecovery.merge(lines, joins: [0, 0.3, 0.3])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].text, "a sentence that trails off and carries on here.")
        XCTAssertEqual(blocks[1].text, "A new thought entirely.")
    }

    func testAGapAlwaysBreaksABlockRegardlessOfTheJoinProbability() {
        let lines = [
            StructureRecovery.Line(text: "first", precededByGap: false),
            StructureRecovery.Line(text: "second", precededByGap: true),
        ]
        XCTAssertEqual(StructureRecovery.merge(lines, joins: [0, 0.99]).count, 2)
    }

    func testClassifySkipsTheHeadingQuestionForBlocksTooLongToBeOne() {
        let blocks = [
            StructureRecovery.Block(text: "Short title", lineIndices: [0], precededByGap: false),
            StructureRecovery.Block(
                text: String(repeating: "long ", count: 40),
                lineIndices: [1],
                precededByGap: true
            ),
        ]
        let questions = StructureRecovery.classifyRequest(for: blocks).questions
        XCTAssertNotNil(questions["hlevel_B000"])
        XCTAssertNil(questions["hlevel_B001"])
        // The companions that always apply are still asked up front.
        XCTAssertNotNil(questions["step_B001"])
        XCTAssertNotNil(questions["callout_B001"])
    }

    func testRendersMarkdownFromJudgmentsWithoutInventingText() {
        let blocks = [
            "Migration to the new build system",
            "Hi everyone, quick heads up about the migration.",
            "Things to do before Monday",
            "Update your local toolchain",
            "Delete the old build cache directory",
            "bun run build",
            "The platform team",
            "The web client team",
            "If the doctor script reports red, stop and ask.",
            "As Dana put it, a migration nobody notices is a good one.",
        ].map { StructureRecovery.Block(text: $0, lineIndices: [], precededByGap: true) }

        func judgment(
            _ kind: StructureRecovery.BlockKind,
            level: StructureRecovery.HeadingLevel = .section,
            step: Double = 0.1,
            callout: String = "note"
        ) -> StructureRecovery.Judgment {
            StructureRecovery.Judgment(
                kind: kind,
                confidence: 0.9,
                headingLevel: level,
                stepProbability: step,
                calloutKind: callout
            )
        }

        let judgments = [
            judgment(.heading, level: .title),
            judgment(.paragraph),
            judgment(.heading, level: .section),
            judgment(.listItem, step: 0.88),
            judgment(.listItem, step: 0.9),
            judgment(.code),
            judgment(.listItem, step: 0.14),
            judgment(.listItem, step: 0.12),
            judgment(.callout, callout: "warning"),
            judgment(.quote),
        ]

        let markdown = StructureRecovery.render(blocks, judgments: judgments)
        XCTAssertTrue(markdown.contains("# Migration to the new build system"))
        XCTAssertTrue(markdown.contains("## Things to do before Monday"))
        // Steps average well above the threshold, so the run is numbered.
        XCTAssertTrue(markdown.contains("1. Update your local toolchain"))
        XCTAssertTrue(markdown.contains("2. Delete the old build cache directory"))
        // Team names are a loose collection, so they are bulleted.
        XCTAssertTrue(markdown.contains("- The platform team"))
        XCTAssertTrue(markdown.contains("```\nbun run build\n```"))
        XCTAssertTrue(markdown.contains("> **Warning:** If the doctor script reports red"))
        XCTAssertTrue(markdown.contains("> As Dana put it"))

        // Every word of the output came from the input.
        for block in blocks {
            XCTAssertTrue(markdown.contains(block.text), "Lost: \(block.text)")
        }
    }
}

@MainActor
final class IntelligenceServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        StubTypeSafeProtocol.reset()
        suiteName = "clio.intelligence.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Stands in for the Keychain so no test writes to the real one.
    private final class KeyStore: @unchecked Sendable {
        private let lock = NSLock()
        private var key: String?
        init(_ key: String?) { self.key = key }
        func load() -> String? { lock.withLock { key } }
        func store(_ new: String?) -> Bool {
            lock.withLock { key = new }
            return true
        }
    }

    /// Builds a service over the given store without touching `isEnabled`, so
    /// a test can read back what the defaults actually held.
    private func loadService(key: String? = "key", store: KeyStore? = nil) -> IntelligenceService {
        let keyStore = store ?? KeyStore(key)
        let service = IntelligenceService(
            defaults: defaults,
            loadAPIKey: { keyStore.load() },
            storeAPIKey: { keyStore.store($0) }
        )
        service.client.session = StubTypeSafeProtocol.makeSession()
        service.client.sleep = { _ in }
        return service
    }

    private func makeService(
        enabled: Bool,
        key: String? = "key",
        store: KeyStore? = nil
    ) -> IntelligenceService {
        let service = loadService(key: key, store: store)
        service.isEnabled = enabled
        return service
    }

    func testIsOffOnAFreshInstall() {
        let service = loadService()
        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(service.isReady)
        XCTAssertEqual(service.statusDescription, "Off. Clio makes no network requests.")
    }

    func testNoRequestIsMadeWhileTheFeatureIsOff() async {
        let service = makeService(enabled: false)
        StubTypeSafeProtocol.enqueue(json: choiceResponseJSON)

        let context = CommandIntentContext(
            hasOpenDocument: true,
            documentExistsOnDisk: true,
            isFocusModeEnabled: false,
            isTypewriterEnabled: false,
            isSidebarVisible: true
        )
        let match = await service.resolveCommand(for: "save this as word", context: context)
        let recovered = await service.recoverStructure(from: String(repeating: "a line of text\n", count: 30))

        XCTAssertNil(match)
        XCTAssertNil(recovered)
        XCTAssertTrue(
            StubTypeSafeProtocol.requests.isEmpty,
            "Nothing may reach the network until the writer turns this on"
        )
    }

    func testNoRequestIsMadeWithoutAKey() async {
        let service = makeService(enabled: true, key: nil)
        XCTAssertFalse(service.isReady)

        let request = TypeSafeRequest(state: .string("x"), questions: [:])
        do {
            _ = try await service.evaluate(request)
            XCTFail("Evaluation without a key must fail closed")
        } catch {
            XCTAssertEqual(error as? TypeSafeError, .missingAPIKey)
        }
        XCTAssertTrue(StubTypeSafeProtocol.requests.isEmpty)
    }

    func testResolvesACommandOnceEnabled() async {
        let service = makeService(enabled: true)
        StubTypeSafeProtocol.enqueue(json: choiceResponseJSON)

        let context = CommandIntentContext(
            hasOpenDocument: true,
            documentExistsOnDisk: true,
            isFocusModeEnabled: false,
            isTypewriterEnabled: false,
            isSidebarVisible: true
        )
        let match = await service.resolveCommand(for: "send this to my editor in Word", context: context)
        XCTAssertEqual(match?.invocation.command, .export)
        XCTAssertEqual(match?.invocation.arguments, ["docx"])
        XCTAssertEqual(StubTypeSafeProtocol.requests.count, 1)
    }

    func testAFailedResolutionFallsBackSilently() async {
        let service = makeService(enabled: true)
        StubTypeSafeProtocol.enqueue(status: 401, json: "{}")

        let context = CommandIntentContext(
            hasOpenDocument: false,
            documentExistsOnDisk: false,
            isFocusModeEnabled: false,
            isTypewriterEnabled: false,
            isSidebarVisible: false
        )
        let match = await service.resolveCommand(for: "make a new document", context: context)
        XCTAssertNil(match, "A failure leaves the palette's own behaviour in charge")
        XCTAssertEqual(service.lastError, TypeSafeError.unauthorized.errorDescription)
    }

    func testPasteFormattingCanBeTurnedOffIndependently() async {
        let service = makeService(enabled: true)
        service.formatsPastes = false
        StubTypeSafeProtocol.enqueue(json: choiceResponseJSON)

        let paste = (0..<30).map { "line number \($0) of some wrapped prose that goes on" }
            .joined(separator: "\n")
        let recovered = await service.recoverStructure(from: paste)
        XCTAssertNil(recovered)
        XCTAssertTrue(StubTypeSafeProtocol.requests.isEmpty)
    }

    func testKeyCheckConfirmsAWorkingKey() async {
        let service = makeService(enabled: true)
        StubTypeSafeProtocol.enqueue(json: choiceResponseJSON)

        await service.verifyKey()
        XCTAssertEqual(service.keyVerification, .valid)
        XCTAssertEqual(service.statusDescription, "Key checked and working.")
        XCTAssertEqual(StubTypeSafeProtocol.requests.count, 1)
    }

    func testKeyCheckReportsARejectedKey() async {
        let service = makeService(enabled: true)
        StubTypeSafeProtocol.enqueue(status: 401, json: "{}")

        await service.verifyKey()
        XCTAssertEqual(
            service.keyVerification,
            .invalid(TypeSafeError.unauthorized.errorDescription ?? "")
        )
    }

    func testKeyCheckStaysBehindTheOptIn() async {
        let service = makeService(enabled: false)
        StubTypeSafeProtocol.enqueue(json: choiceResponseJSON)

        await service.verifyKey()
        XCTAssertTrue(
            StubTypeSafeProtocol.requests.isEmpty,
            "Checking a key is still a request, so it waits for the opt-in too"
        )
    }

    func testStoringANewKeyDiscardsTheOldResult() async {
        let store = KeyStore("key")
        let service = makeService(enabled: true, store: store)
        StubTypeSafeProtocol.enqueue(json: choiceResponseJSON)
        await service.verifyKey()
        XCTAssertEqual(service.keyVerification, .valid)

        service.setAPIKey("a-different-key")
        XCTAssertEqual(store.load(), "a-different-key")
        XCTAssertTrue(service.hasAPIKey)
        XCTAssertEqual(
            service.keyVerification,
            .unchecked,
            "A new key has not been checked, whatever the last one's result was"
        )
    }

    func testRemovingTheKeyClearsItFromTheStoreAndTheUI() {
        let store = KeyStore("key")
        let service = makeService(enabled: true, store: store)
        XCTAssertTrue(service.isReady)

        service.clearAPIKey()
        XCTAssertNil(store.load())
        XCTAssertFalse(service.hasAPIKey)
        XCTAssertFalse(service.isReady)
        XCTAssertEqual(
            service.statusDescription,
            "No key stored. Add your own TypeSafe API key to finish setting this up."
        )
    }

    func testEachKeyStoreIsIndependent() {
        // Two accounts on one Mac resolve to two stores; neither sees the other.
        let mine = makeService(enabled: true, store: KeyStore("my-key"))
        let theirs = makeService(enabled: true, store: KeyStore(nil))
        XCTAssertTrue(mine.isReady)
        XCTAssertFalse(theirs.isReady)
    }

    func testSettingsAreRemembered() {
        let service = makeService(enabled: true)
        service.formatsPastes = false

        // Reload from the same defaults without setting anything.
        let reloaded = loadService()
        XCTAssertTrue(reloaded.isEnabled)
        XCTAssertFalse(reloaded.formatsPastes)
    }
}
