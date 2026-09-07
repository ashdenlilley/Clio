import Foundation

/// Client-launched stdio adapter, not a daemon. Never launches Clio or accesses
/// documents itself. All authorization remains in the running application.
final class Bridge: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let token: String
    private let lock = NSLock()
    private let outputLock = NSLock()
    private var sessionID: String?
    private var version = "2025-11-25"
    private let pending = DispatchGroup()
    private let slots = DispatchSemaphore(value: 16)
    private lazy var http: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 110
        configuration.timeoutIntervalForResource = 115
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(token: String) { self.token = token }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward a bearer token to another origin.
    }

    func run() {
        var buffer = Data()
        while let data = try? FileHandle.standardInput.read(upToCount: 16_384), !data.isEmpty {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard line.count <= 1_048_576 else { fail(); return }
                if !line.isEmpty { forward(line) }
            }
            guard buffer.count <= 1_048_576 else { fail(); return }
        }
        if !buffer.isEmpty { forward(buffer) }
        _ = pending.wait(timeout: .now() + 120)
        http.invalidateAndCancel()
    }

    private func forward(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let method = object["method"] as? String else { fail(); return }
        let id = object["id"]
        guard slots.wait(timeout: .now()) == .success else {
            if let id { emitError(id, message: "Too many outstanding requests") }; return
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:19847/mcp")!)
        request.httpMethod = "POST"; request.httpBody = line
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        lock.lock()
        if method != "initialize" {
            request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
            request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        lock.unlock()
        pending.enter()
        let sequencing = DispatchSemaphore(value: 0)
        http.dataTask(with: request) { [self] data, response, error in
            defer { slots.signal(); pending.leave(); sequencing.signal() }
            guard error == nil, let response = response as? HTTPURLResponse,
                  [200, 202].contains(response.statusCode) else {
                if let id { emitError(id, message: "Clio is unavailable or access was revoked. Open Clio and check MCP Settings.") }
                return
            }
            if method == "initialize", let session = response.value(forHTTPHeaderField: "MCP-Session-Id") {
                lock.lock(); sessionID = session
                if let data, let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let result = reply["result"] as? [String: Any], let negotiated = result["protocolVersion"] as? String { version = negotiated }
                lock.unlock()
            }
            if let data, !data.isEmpty, data.count <= 4_194_304 { emit(data) }
        }.resume()
        // Preserve the initialization barrier while allowing concurrent calls
        // and cancellation notifications once a session is initialized.
        if method == "initialize" || method == "notifications/initialized" { sequencing.wait() }
    }

    private func emitError(_ id: Any, message: String) {
        if let data = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id,
            "error": ["code": -32000, "message": message]]) { emit(data) }
    }
    private func emit(_ data: Data) {
        outputLock.lock(); defer { outputLock.unlock() }
        try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }
    private func fail() { try? FileHandle.standardError.write(contentsOf: Data("Invalid or oversized MCP input.\n".utf8)) }
}

if let token = ProcessInfo.processInfo.environment["CLIO_MCP_TOKEN"],
   let bytes = Data(base64Encoded: token), bytes.count == 32 {
    Bridge(token: token).run()
} else {
    try? FileHandle.standardError.write(contentsOf: Data("Set CLIO_MCP_TOKEN using a token from Clio MCP Settings.\n".utf8))
    exit(1)
}
