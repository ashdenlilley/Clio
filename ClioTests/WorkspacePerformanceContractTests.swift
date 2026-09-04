import Foundation
import XCTest
@testable import Clio

final class WorkspacePerformanceContractTests: XCTestCase {
    func testGuaranteedWorkspaceContract() async throws {
        guard ProcessInfo.processInfo.environment["CLIO_RUN_PERFORMANCE_CONTRACT"] == "1"
                || FileManager.default.fileExists(atPath: "/tmp/ClioRunPerformanceContract") else {
            throw XCTSkip("Set CLIO_RUN_PERFORMANCE_CONTRACT=1 for the 25k / 2 GiB release gate.")
        }

        try await withTemporaryDirectory { baseURL in
            let workspaceURL = baseURL.appendingPathComponent("workspace", isDirectory: true)
            try PerformanceFixtureGenerator.writeWorkspace(
                at: workspaceURL,
                documentCount: PerformanceContract.guaranteedDocumentCount,
                totalUTF8ByteCount: PerformanceContract.guaranteedWorkspaceByteCount
            )
            let workspace = WorkspaceDescriptor(rootURL: workspaceURL)
            let identityStore = DocumentIdentityStore(
                storageURL: baseURL.appendingPathComponent("identities.json")
            )
            let index = try SQLiteSearchIndex(
                databaseURL: baseURL.appendingPathComponent("contract.sqlite3"),
                identityStore: identityStore
            )
            let clock = ContinuousClock()
            let indexStart = clock.now
            try await index.rebuild(workspaces: [workspace], policy: .default)
            let indexDuration = indexStart.duration(to: clock.now)
            print("CLIO_PERFORMANCE fresh_index=\(indexDuration)")
            XCTAssertLessThan(indexDuration, PerformanceContract.freshIndex)

            // Include opening a new connection and actor dispatch, not just
            // consumption of a stream whose producer may already have finished.
            // This is a cold connection, not a claim that the OS cache is cold.
            let cold = try await timings(clock: clock) {
                let reopened = try SQLiteSearchIndex(
                    databaseURL: baseURL.appendingPathComponent("contract.sqlite3"),
                    identityStore: identityStore
                )
                return await reopened.search(WorkspaceSearchQuery(text: "workspace"))
            }
            print("CLIO_PERFORMANCE cold_connection_first=\(cold.first) settled=\(cold.settled)")
            XCTAssertLessThanOrEqual(cold.first, PerformanceContract.coldSearchFirstResult)
            XCTAssertLessThanOrEqual(cold.settled, PerformanceContract.searchSettled)

            var quickFirst: [Duration] = []
            var quickSettled: [Duration] = []
            var searchFirst: [Duration] = []
            var searchSettled: [Duration] = []
            for iteration in 0..<25 {
                let quick = try await timings(clock: clock) {
                    await index.quickOpen(
                        WorkspaceSearchQuery(text: String(format: "document-%06d", iteration * 997))
                    )
                }
                quickFirst.append(quick.first)
                quickSettled.append(quick.settled)

                let search = try await timings(clock: clock) {
                    await index.search(
                        WorkspaceSearchQuery(text: iteration.isMultiple(of: 2) ? "workspace" : "revision")
                    )
                }
                searchFirst.append(search.first)
                searchSettled.append(search.settled)
            }
            XCTAssertLessThanOrEqual(percentile95(quickFirst), PerformanceContract.quickOpenFirstResultP95)
            XCTAssertLessThanOrEqual(percentile95(quickSettled), PerformanceContract.quickOpenSettledP95)
            XCTAssertLessThanOrEqual(percentile95(searchFirst), PerformanceContract.warmSearchFirstResult)
            XCTAssertLessThanOrEqual(percentile95(searchSettled), PerformanceContract.searchSettled)
            print("CLIO_PERFORMANCE quick_first_p95=\(percentile95(quickFirst)) quick_settled_p95=\(percentile95(quickSettled)) search_first_p95=\(percentile95(searchFirst)) search_settled_p95=\(percentile95(searchSettled))")

            let changedURL = workspaceURL.appendingPathComponent("000/document-000000.md")
            try Data("external reflection token".utf8).write(to: changedURL, options: .atomic)
            let eventStart = clock.now
            try await index.apply([
                WorkspaceEvent(
                    workspaceID: workspace.id,
                    kind: .modified,
                    fileURL: changedURL,
                    origin: .external
                ),
            ])
            let reflected = try await finalBatch(
                from: await index.search(WorkspaceSearchQuery(text: "reflection"))
            )
            XCTAssertEqual(reflected.results.count, 1)
            let eventDuration = eventStart.duration(to: clock.now)
            print("CLIO_PERFORMANCE index_event_to_query=\(eventDuration)")
            XCTAssertLessThan(eventDuration, PerformanceContract.externalChangeReflection)
        }
    }

    func testStressCorpusDegradesWithoutFailure() async throws {
        guard ProcessInfo.processInfo.environment["CLIO_RUN_STRESS_CONTRACT"] == "1"
                || FileManager.default.fileExists(atPath: "/tmp/ClioRunStressContract") else {
            throw XCTSkip("Set CLIO_RUN_STRESS_CONTRACT=1 for the 100k / 10 GiB stress gate.")
        }

        try await withTemporaryDirectory { baseURL in
            let workspaceURL = baseURL.appendingPathComponent("stress", isDirectory: true)
            try PerformanceFixtureGenerator.writeWorkspace(
                at: workspaceURL,
                documentCount: PerformanceContract.stressDocumentCount,
                totalUTF8ByteCount: PerformanceContract.stressWorkspaceByteCount
            )
            let index = try SQLiteSearchIndex(
                databaseURL: baseURL.appendingPathComponent("stress.sqlite3"),
                identityStore: DocumentIdentityStore(
                    storageURL: baseURL.appendingPathComponent("identities.json")
                )
            )
            let clock = ContinuousClock()
            let started = clock.now
            try await index.rebuild(
                workspaces: [WorkspaceDescriptor(rootURL: workspaceURL)],
                policy: .default
            )
            print("CLIO_PERFORMANCE stress_index=\(started.duration(to: clock.now))")
            let result = try await finalBatch(
                from: await index.search(WorkspaceSearchQuery(text: "workspace", limit: 100))
            )
            XCTAssertFalse(result.results.isEmpty)
            XCTAssertLessThanOrEqual(result.results.count, 100)
            // Indexing must remain read-only even at the stress tier.
            for documentIndex in [0, 49_999, 99_999] {
                let baseSize = PerformanceContract.stressWorkspaceByteCount
                    / Int64(PerformanceContract.stressDocumentCount)
                let remainder = PerformanceContract.stressWorkspaceByteCount
                    % Int64(PerformanceContract.stressDocumentCount)
                let expected = PerformanceFixtureGenerator.document(
                    index: documentIndex,
                    utf8ByteCount: Int(baseSize + (Int64(documentIndex) < remainder ? 1 : 0))
                )
                let relativePath = String(
                    format: "%03d/document-%06d.md", documentIndex / 1_000, documentIndex
                )
                XCTAssertEqual(
                    try Data(contentsOf: workspaceURL.appendingPathComponent(relativePath)),
                    Data(expected.utf8)
                )
            }
        }
    }
}

private extension WorkspacePerformanceContractTests {
    func timings(
        clock: ContinuousClock,
        makeStream: () async throws -> AsyncThrowingStream<SearchBatch, Error>
    ) async throws -> (first: Duration, settled: Duration) {
        let start = clock.now
        var first: Duration?
        for try await batch in try await makeStream() {
            if first == nil, !batch.results.isEmpty { first = start.duration(to: clock.now) }
            if batch.isFinal {
                XCTAssertNotNil(first, "Latency measurements require a useful result.")
                return (first ?? start.duration(to: clock.now), start.duration(to: clock.now))
            }
        }
        let elapsed = start.duration(to: clock.now)
        return (first ?? elapsed, elapsed)
    }

    func percentile95(_ samples: [Duration]) -> Duration {
        let ordered = samples.sorted()
        let index = min(ordered.count - 1, Int((Double(ordered.count) * 0.95).rounded(.up)) - 1)
        return ordered[max(0, index)]
    }

    func finalBatch(
        from stream: AsyncThrowingStream<SearchBatch, Error>
    ) async throws -> SearchBatch {
        var final = SearchBatch(results: [], isFinal: true)
        for try await batch in stream { final = batch }
        return final
    }

    func withTemporaryDirectory<T>(
        _ operation: (URL) async throws -> T
    ) async throws -> T {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioPerformanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        return try await operation(directoryURL)
    }
}
