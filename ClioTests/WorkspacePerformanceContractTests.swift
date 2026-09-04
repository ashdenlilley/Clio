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
            let index = try SQLiteSearchIndex(
                databaseURL: baseURL.appendingPathComponent("contract.sqlite3")
            )
            let clock = ContinuousClock()
            let indexStart = clock.now
            try await index.rebuild(workspaces: [workspace], policy: .default)
            let indexDuration = indexStart.duration(to: clock.now)
            XCTAssertLessThan(indexDuration, PerformanceContract.freshIndex)

            var quickFirst: [Duration] = []
            var quickSettled: [Duration] = []
            var searchFirst: [Duration] = []
            var searchSettled: [Duration] = []
            for iteration in 0..<25 {
                let quick = try await timings(
                    clock: clock,
                    stream: await index.quickOpen(
                        WorkspaceSearchQuery(text: String(format: "document-%06d", iteration * 997))
                    )
                )
                quickFirst.append(quick.first)
                quickSettled.append(quick.settled)

                let search = try await timings(
                    clock: clock,
                    stream: await index.search(
                        WorkspaceSearchQuery(text: iteration.isMultiple(of: 2) ? "workspace" : "revision")
                    )
                )
                searchFirst.append(search.first)
                searchSettled.append(search.settled)
            }
            XCTAssertLessThanOrEqual(percentile95(quickFirst), PerformanceContract.quickOpenFirstResultP95)
            XCTAssertLessThanOrEqual(percentile95(quickSettled), PerformanceContract.quickOpenSettledP95)
            XCTAssertLessThanOrEqual(percentile95(searchFirst), PerformanceContract.warmSearchFirstResult)
            XCTAssertLessThanOrEqual(percentile95(searchSettled), PerformanceContract.searchSettled)

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
            let eventDuration = eventStart.duration(to: clock.now)
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
                databaseURL: baseURL.appendingPathComponent("stress.sqlite3")
            )
            try await index.rebuild(
                workspaces: [WorkspaceDescriptor(rootURL: workspaceURL)],
                policy: .default
            )
            let result = try await finalBatch(
                from: await index.search(WorkspaceSearchQuery(text: "workspace", limit: 100))
            )
            XCTAssertFalse(result.results.isEmpty)
        }
    }
}

private extension WorkspacePerformanceContractTests {
    func timings(
        clock: ContinuousClock,
        stream: AsyncThrowingStream<SearchBatch, Error>
    ) async throws -> (first: Duration, settled: Duration) {
        let start = clock.now
        var first: Duration?
        for try await batch in stream {
            if first == nil { first = start.duration(to: clock.now) }
            if batch.isFinal {
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
