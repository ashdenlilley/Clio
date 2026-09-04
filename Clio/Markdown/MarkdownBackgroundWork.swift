import Foundation

/// Runs parser work away from the UI executor while keeping abandoned parser
/// generations bounded. cmark does not expose an interruption hook while it is
/// constructing an AST, so cancelled callers are released immediately and at
/// most two already-running generations are allowed to finish in the pool.
enum MarkdownBackgroundWork {
    struct CancellationProbe: @unchecked Sendable {
        fileprivate let isCancelled: @Sendable () -> Bool

        func check() throws {
            if isCancelled() { throw CancellationError() }
        }
    }

    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "olympus.clio.markdown-parser"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    static func run<Value: Sendable>(
        _ body: @escaping @Sendable (CancellationProbe) throws -> Value
    ) async throws -> Value {
        let state = WorkState<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let operation = BlockOperation {
                    do {
                        let probe = CancellationProbe(isCancelled: {
                            state.cancelled
                        })
                        try probe.check()
                        let value = try body(probe)
                        try probe.check()
                        state.finish(.success(value))
                    } catch {
                        state.finish(.failure(error))
                    }
                }
                state.install(continuation: continuation, operation: operation)
                queue.addOperation(operation)
            }
        } onCancel: {
            state.cancel()
        }
    }
}

private final class WorkState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var operation: Operation?
    private var didResolve = false
    private var wasCancelled = false

    var cancelled: Bool {
        lock.withLock { wasCancelled }
    }

    func install(
        continuation: CheckedContinuation<Value, Error>,
        operation: Operation
    ) {
        let alreadyCancelled = lock.withLock {
            guard !didResolve else { return true }
            self.continuation = continuation
            self.operation = operation
            return false
        }
        if alreadyCancelled {
            operation.cancel()
            continuation.resume(throwing: CancellationError())
        }
    }

    func finish(_ result: Result<Value, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Value, Error>? in
            guard !didResolve else { return nil }
            didResolve = true
            operation = nil
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func cancel() {
        let resolution = lock.withLock {
            wasCancelled = true
            operation?.cancel()
            operation = nil
            guard !didResolve else {
                return Optional<CheckedContinuation<Value, Error>>.none
            }
            didResolve = true
            defer { continuation = nil }
            return continuation
        }
        resolution?.resume(throwing: CancellationError())
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
