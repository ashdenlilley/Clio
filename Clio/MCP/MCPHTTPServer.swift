import Foundation
import Network

struct MCPHTTPRequest {
    let method: String
    let headers: [String: String]
    let body: Data

    /// Deliberately supports a single, length-delimited request per connection.
    /// Rejects ambiguous framing rather than guessing (including duplicate headers).
    static func decode(_ data: Data, port: UInt16) throws -> MCPHTTPRequest? {
        guard data.count <= MCPLoopbackPolicy.maximumBodyBytes + 16_384 else {
            throw MCPAccessError.oversizedRequest
        }
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= 16_384 else { throw MCPAccessError.oversizedRequest }
            return nil
        }
        guard separator.lowerBound <= 16_384,
              let head = String(data: data[..<separator.lowerBound], encoding: .utf8) else {
            throw MCPAccessError.invalidRequest
        }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].components(separatedBy: " ")
        guard first.count == 3, first[1] == "/mcp", first[2] == "HTTP/1.1",
              ["POST", "GET", "DELETE"].contains(first[0]) else { throw MCPAccessError.invalidRequest }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw MCPAccessError.invalidRequest }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }),
                  headers[name] == nil else { throw MCPAccessError.invalidRequest }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw MCPAccessError.invalidRequest
            }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil,
              let host = headers["host"] else { throw MCPAccessError.invalidRequest }
        let rawLength = headers["content-length"] ?? (first[0] == "POST" ? "" : "0")
        guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ (48...57).contains($0) }),
              let length = Int(rawLength) else { throw MCPAccessError.invalidRequest }
        try MCPLoopbackPolicy(port: port).validate(host: host, origin: headers["origin"], bodyByteCount: length)
        let body = data[separator.upperBound...]
        guard body.count <= length else { throw MCPAccessError.invalidRequest }
        guard body.count == length else { return nil }
        if first[0] == "POST" {
            guard headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "application/json",
                  headers["accept"]?.contains("application/json") == true,
                  headers["accept"]?.contains("text/event-stream") == true else {
                throw MCPAccessError.invalidRequest
            }
        } else if length != 0 { throw MCPAccessError.invalidRequest }
        return MCPHTTPRequest(method: first[0], headers: headers, body: Data(body))
    }
}

struct MCPHTTPResponse {
    let status: Int
    var headers: [String: String] = [:]
    var body = Data()

    func encoded() -> Data {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized",
                      403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                      413: "Content Too Large", 503: "Service Unavailable"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}

@MainActor
final class MCPHTTPServer {
    static let port: UInt16 = 19847
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var timers: [UUID: Task<Void, Never>] = [:]
    private var generation = UUID()
    var handle: ((MCPHTTPRequest) async -> MCPHTTPResponse)?
    var stateChanged: ((String) -> Void)?

    func start() throws {
        stop()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let epoch = generation
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == epoch else { return }
                switch state {
                case .ready: self.stateChanged?("Listening on 127.0.0.1:\(Self.port)")
                case .failed: self.stop(); self.stateChanged?("Unable to listen. Port may be in use.")
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.generation == epoch, self.connections.count < 16 else {
                    connection.cancel(); return
                }
                let id = UUID()
                self.connections[id] = connection
                connection.start(queue: .main)
                self.timers[id] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { return }
                    self?.close(id)
                }
                self.receive(id, bytes: Data())
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        generation = UUID()
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
    }

    private func close(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
        timers.removeValue(forKey: id)?.cancel()
    }

    private func receive(_ id: UUID, bytes: Data) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                let accumulated = bytes + (data ?? Data())
                do {
                    if let request = try MCPHTTPRequest.decode(accumulated, port: Self.port) {
                        self.timers.removeValue(forKey: id)?.cancel()
                        self.timers[id] = Task { [weak self] in
                            try? await Task.sleep(for: .seconds(120))
                            guard !Task.isCancelled else { return }
                            self?.close(id)
                        }
                        // Disconnect is NOT cancellation. The router owns in-flight
                        // tasks and replay state, even when delivery is interrupted.
                        let response = await self.handle?(request) ?? MCPHTTPResponse(status: 503)
                        self.send(response, to: id)
                    } else if done || error != nil { self.close(id) }
                    else { self.receive(id, bytes: accumulated) }
                } catch {
                    let status: Int
                    switch error as? MCPAccessError {
                    case .forbiddenOrigin, .invalidHost: status = 403
                    case .oversizedRequest: status = 413
                    default: status = 400
                    }
                    self.send(MCPHTTPResponse(status: status), to: id)
                }
            }
        }
    }

    private func send(_ response: MCPHTTPResponse, to id: UUID) {
        connections[id]?.send(content: response.encoded(), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(id) }
        })
    }
}
