import Foundation
import BobbCore

/// Credentials stay on the configured origin. Redirects must be reconfigured
/// explicitly; URLSession's shared cookies and credential store are unused.
final class MCPNetworkDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
@MainActor
final class MCPHTTPTransport {
    private let config: MCPConfiguration
    private let endpoint: URL
    private let session: URLSession
    private var postURL: URL
    private var sessionID: String?
    var protocolVersion = "2025-11-25"
    private var stream: Task<Void, Never>?
    private var legacy = false
    private var closed = false
    var receive: (JSONValue) -> Void = { _ in }
    var ended: () -> Void = {}
    init(configuration: MCPConfiguration) throws {
        guard let url = configuration.endpoint.flatMap(MCPRemoteProtocol.endpoint) else { throw ConnectorError.configuration }
        config = configuration; endpoint = url; postURL = url
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.urlCredentialStorage = nil; c.urlCache = nil
        c.timeoutIntervalForRequest = 60; c.timeoutIntervalForResource = 600
        session = URLSession(configuration: c, delegate: MCPNetworkDelegate(), delegateQueue: nil)
    }
    func start() async throws {
        if config.transport == .sse { try await startLegacy() }
    }
    private func request(_ url: URL, method: String) async throws -> URLRequest {
        guard !closed, !Task.isCancelled, MCPRemoteProtocol.sameOrigin(endpoint, url) else { throw CancellationError() }
        var r = URLRequest(url: url); r.httpMethod = method
        r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in try MCPSecrets.headers(config) { r.setValue(value, forHTTPHeaderField: name) }
        if config.oauth != nil, let token = try await MCPOAuth.bearer(config) { r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let sessionID { r.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id") }
        if method != "DELETE" { r.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        return r
    }
    func send(_ value: JSONValue) async throws {
        let isInitialize = value["method"]?.stringValue == "initialize"
        var r = try await request(postURL, method: "POST")
        if isInitialize { r.setValue(nil, forHTTPHeaderField: "MCP-Protocol-Version") }
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(value)
        let (bytes, response) = try await session.bytes(for: r)
        guard let http = response as? HTTPURLResponse else { throw ConnectorError.response }
        if !legacy, isInitialize, [404, 405].contains(http.statusCode) {
            // Only an unanswered initialize can negotiate the old transport.
            try await startLegacy(); try await send(value); return
        }
        try check(http)
        if let id = http.value(forHTTPHeaderField: "MCP-Session-Id") {
            guard !id.isEmpty, id.count <= 1024, id.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { throw ConnectorError.response }
            sessionID = id
        }
        if http.statusCode == 202 || http.statusCode == 204 { return }
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if type.hasPrefix("text/event-stream") {
            try await events(bytes, expectedID: value["id"]?.stringValue)
        } else if type.hasPrefix("application/json") {
            let data = try await Self.bounded(bytes)
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw ConnectorError.response }
            receive(message)
        } else { throw ConnectorError.response }
    }
    private func check(_ response: HTTPURLResponse) throws {
        if response.statusCode == 401 || response.statusCode == 403 { throw ConnectorError.authorization }
        if response.statusCode == 404, sessionID != nil { throw ConnectorError.sessionExpired }
        guard (200...299).contains(response.statusCode) else { throw ConnectorError.http(response.statusCode) }
    }
    private static func bounded(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation(); data.append(byte)
            guard data.count <= 1_000_000 else { throw ConnectorError.response }
        }
        return data
    }
    private func events(_ bytes: URLSession.AsyncBytes, expectedID: String? = nil) async throws {
        var line = Data(), decoder = SSEDecoder()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            if byte != 10 {
                line.append(byte); guard line.count <= 1_000_000 else { throw ConnectorError.response }; continue
            }
            guard let text = String(data: line, encoding: .utf8) else { throw ConnectorError.response }
            line.removeAll(keepingCapacity: true)
            guard let event = try decoder.line(text) else { continue }
            if event.event == "endpoint", legacy {
                guard let url = URL(string: event.data, relativeTo: endpoint)?.absoluteURL,
                      MCPRemoteProtocol.endpoint(url.absoluteString) != nil, MCPRemoteProtocol.sameOrigin(endpoint, url) else { throw ConnectorError.configuration }
                postURL = url; legacyReady = true
            } else if event.event == "message" {
                guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(event.data.utf8)) else { throw ConnectorError.response }
                receive(value)
                if let expectedID, value["id"]?.stringValue == expectedID, value["method"] == nil { return }
            }
        }
        if expectedID != nil { throw ConnectorError.response }
    }
    private var legacyReady = false
    private func startLegacy() async throws {
        stream?.cancel(); legacy = true; legacyReady = false
        let (bytes, response) = try await session.bytes(for: request(endpoint, method: "GET"))
        guard let http = response as? HTTPURLResponse else { throw ConnectorError.response }; try check(http)
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true else { throw ConnectorError.response }
        stream = Task { [weak self] in
            guard let self else { return }
            do { try await self.events(bytes) } catch { if !Task.isCancelled { self.ended() } }
        }
        let deadline = Date().addingTimeInterval(15)
        while !legacyReady {
            try Task.checkCancellation(); guard Date() < deadline, !closed else { throw ConnectorError.response }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    func listen() {
        guard !legacy, stream == nil, !closed else { return }
        stream = Task { [weak self] in
            guard let self else { return }
            do {
                let (bytes, response) = try await self.session.bytes(for: self.request(self.endpoint, method: "GET"))
                guard let http = response as? HTTPURLResponse else { return }
                if http.statusCode == 405 { return }
                try self.check(http)
                guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true else { return }
                try await self.events(bytes)
            } catch { /* Optional notifications stream. Requests still carry their own responses. */ }
        }
    }
    func close() {
        closed = true; stream?.cancel(); stream = nil
        session.invalidateAndCancel(); sessionID = nil
    }
}
