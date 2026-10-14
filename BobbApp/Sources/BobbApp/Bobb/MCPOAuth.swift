import AppKit
import CryptoKit
import Security
@preconcurrency import Network
import BobbCore

/// Native public OAuth client: external browser, loopback redirect, S256 PKCE.
/// No access token, client secret, verifier or authorization code reaches bobbd.
@MainActor
enum MCPOAuth {
    private struct Token: Codable {
        var accessToken: String
        var refreshToken: String?
        var expires: Date
        var issuer: String
        var clientId: String
        var tokenEndpoint: String
        var resource: String
    }
    private static var refreshing: [String: Task<String, Error>] = [:]
    private static func account(_ config: MCPConfiguration) -> String {
        "oauth-" + SHA256.hash(data: Data(((config.endpoint ?? "") + "\n" + (config.oauth?.clientId ?? "") + "\n" + (config.oauth?.scope ?? "") + "\n" + (config.oauth?.clientSecretReference ?? "")).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func logout(_ config: MCPConfiguration) {
        let id = account(config); refreshing.removeValue(forKey: id)?.cancel(); MCPSecrets.remove(id)
    }
    static func bearer(_ config: MCPConfiguration) async throws -> String? {
        let id = account(config)
        guard let raw = try? MCPSecrets.read(id), let token = try? JSONDecoder().decode(Token.self, from: Data(raw.utf8)),
              token.resource == resource(config)?.absoluteString else { throw ConnectorError.authorization }
        if token.expires.timeIntervalSinceNow > 60 { return token.accessToken }
        if let current = refreshing[id] { return try await current.value }
        guard let refresh = token.refreshToken else { throw ConnectorError.authorization }
        let task = Task { () throws -> String in
            guard let url = MCPRemoteProtocol.endpoint(token.tokenEndpoint) else { throw ConnectorError.configuration }
            var fields = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": token.clientId, "resource": token.resource]
            if let reference = config.oauth?.clientSecretReference { fields["client_secret"] = try MCPSecrets.read(reference) }
            let response = try await json(url, method: "POST", form: fields)
            var renewed = try parseToken(response, issuer: token.issuer, clientId: token.clientId, endpoint: token.tokenEndpoint, resource: token.resource)
            renewed.refreshToken = renewed.refreshToken ?? token.refreshToken
            try Task.checkCancellation(); try persist(renewed, account: id)
            return renewed.accessToken
        }
        refreshing[id] = task
        defer { refreshing[id] = nil }
        return try await task.value
    }
    static func login(_ config: MCPConfiguration, openAuthorization: @escaping @MainActor (URL) async -> Bool = { NSWorkspace.shared.open($0) }) async throws {
        guard config.transport != .stdio, let resource = resource(config), let oauth = config.oauth else { throw ConnectorError.configuration }
        let metadata = try await protectedResource(resource)
        guard let metadataResource = metadata["resource"]?.stringValue.flatMap(MCPRemoteProtocol.endpoint),
              metadataResource.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == resource.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              let issuers = metadata["authorization_servers"]?.arrayValue, !issuers.isEmpty else { throw ConnectorError.configuration }
        var server: JSONValue?
        var issuer: URL?
        for candidate in issuers.prefix(5) {
            guard let url = candidate.stringValue.flatMap(MCPRemoteProtocol.endpoint), url.query == nil else { continue }
            for discovery in MCPRemoteProtocol.authorizationMetadataURLs(url) {
                if let result = try? await json(discovery), result["issuer"]?.stringValue == url.absoluteString { server = result; issuer = url; break }
            }
            if server != nil { break }
        }
        guard let server, let issuer,
              let authorizationURL = server["authorization_endpoint"]?.stringValue.flatMap(MCPRemoteProtocol.endpoint),
              let tokenURL = server["token_endpoint"]?.stringValue.flatMap(MCPRemoteProtocol.endpoint),
              server["code_challenge_methods_supported"]?.arrayValue?.contains(.string("S256")) == true else { throw ConnectorError.configuration }
        let state = try random(), verifier = try random()
        let callback = MCPAuthorizationCallback(state: state)
        let redirect = try await callback.start(); defer { callback.close() }
        var clientId = oauth.clientId
        if clientId.isEmpty {
            guard let registration = server["registration_endpoint"]?.stringValue.flatMap(MCPRemoteProtocol.endpoint) else { throw ConnectorError.registration }
            let result = try await json(registration, method: "POST", body: ["client_name": "Bobb", "redirect_uris": .array([.string(redirect.absoluteString)]),
                "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"], "token_endpoint_auth_method": "none"])
            guard let registered = result["client_id"]?.stringValue, !registered.isEmpty,
                  (result["token_endpoint_auth_method"]?.stringValue ?? "none") == "none" else { throw ConnectorError.registration }
            clientId = registered
        }
        var parts = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)!
        let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let scope = oauth.scope ?? metadata["scopes_supported"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " ") ?? ""
        var parameters = ["response_type": "code", "client_id": clientId, "redirect_uri": redirect.absoluteString,
            "state": state, "code_challenge": challenge, "code_challenge_method": "S256", "resource": resource.absoluteString]
        if !scope.isEmpty { parameters["scope"] = scope }
        let reserved = Set(parameters.keys)
        parts.queryItems = (parts.queryItems ?? []).filter { !reserved.contains($0.name) } + parameters.keys.sorted().map { URLQueryItem(name: $0, value: parameters[$0]) }
        guard let url = parts.url, await openAuthorization(url) else { throw ConnectorError.authorization }
        let code = try await callback.code()
        var fields = ["grant_type": "authorization_code", "code": code, "redirect_uri": redirect.absoluteString,
            "client_id": clientId, "code_verifier": verifier, "resource": resource.absoluteString]
        if let reference = oauth.clientSecretReference { fields["client_secret"] = try MCPSecrets.read(reference) }
        let result = try await json(tokenURL, method: "POST", form: fields)
        let token = try parseToken(result, issuer: issuer.absoluteString, clientId: clientId, endpoint: tokenURL.absoluteString, resource: resource.absoluteString)
        try Task.checkCancellation(); try persist(token, account: account(config))
    }
    private static func resource(_ config: MCPConfiguration) -> URL? {
        guard let endpoint = config.endpoint.flatMap(MCPRemoteProtocol.endpoint), var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        parts.query = nil; return parts.url
    }
    private static func protectedResource(_ resource: URL) async throws -> JSONValue {
        // Discovery requests contain no connector headers or access tokens.
        let (challenge, _) = (try? await challengeMetadata(resource)) ?? (nil, nil)
        var urls = MCPRemoteProtocol.protectedMetadataURLs(resource)
        if let challenge { urls.insert(challenge, at: 0) }
        for url in urls { if let value = try? await json(url), value["resource"] != nil { return value } }
        throw ConnectorError.authorization
    }
    private static func challengeMetadata(_ resource: URL) async throws -> (URL?, String?) {
        let session = network(); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: resource); request.httpMethod = "GET"; request.timeoutInterval = 15
        let (_, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 401,
              let header = response.value(forHTTPHeaderField: "WWW-Authenticate") else { return (nil, nil) }
        let regex = try NSRegularExpression(pattern: #"resource_metadata="([^"]+)""#)
        let range = NSRange(header.startIndex..., in: header)
        guard let match = regex.firstMatch(in: header, range: range), let value = Range(match.range(at: 1), in: header) else { return (nil, nil) }
        return (MCPRemoteProtocol.endpoint(String(header[value])), nil)
    }
    private static func network() -> URLSession {
        let c = URLSessionConfiguration.ephemeral; c.httpCookieStorage = nil; c.urlCredentialStorage = nil; c.urlCache = nil
        c.timeoutIntervalForRequest = 30; c.timeoutIntervalForResource = 60
        return URLSession(configuration: c, delegate: MCPNetworkDelegate(), delegateQueue: nil)
    }
    private static func json(_ url: URL, method: String = "GET", body: JSONValue? = nil, form: [String: String]? = nil) async throws -> JSONValue {
        let session = network(); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.httpMethod = method; request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let form { request.httpBody = MCPRemoteProtocol.form(form); request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw ConnectorError.authorization }
        var data = Data()
        for try await byte in bytes { try Task.checkCancellation(); data.append(byte); guard data.count <= 1_000_000 else { throw ConnectorError.response } }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    private static func parseToken(_ response: JSONValue, issuer: String, clientId: String, endpoint: String, resource: String) throws -> Token {
        guard response["token_type"]?.stringValue?.lowercased() == "bearer", let access = response["access_token"]?.stringValue,
              !access.isEmpty, access.count <= 16_000, !access.contains(where: { $0.isWhitespace || $0 == "\0" }) else { throw ConnectorError.authorization }
        return Token(accessToken: access, refreshToken: response["refresh_token"]?.stringValue,
            expires: Date().addingTimeInterval(max(0, min(response["expires_in"]?.numberValue ?? 3600, 86400 * 365))),
            issuer: issuer, clientId: clientId, tokenEndpoint: endpoint, resource: resource)
    }
    private static func persist(_ token: Token, account: String) throws { try MCPSecrets.replace(account, value: String(decoding: JSONEncoder().encode(token), as: UTF8.self)) }
    private static func random() throws -> String {
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw ConnectorError.authorization }; return base64url(data)
    }
    private static func base64url(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

@MainActor
private final class MCPAuthorizationCallback {
    private let state: String
    private var listener: NWListener?
    private var receivedCode: String?
    private var denied = false, ready = false, closed = false
    private var callbackURL: URL?
    private var connections: [UUID: NWConnection] = [:]
    init(state: String) { self.state = state }
    func start() async throws -> URL {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params); self.listener = listener
        listener.stateUpdateHandler = { [weak self] value in Task { @MainActor [weak self] in
            if case .ready = value { self?.ready = true }
            if case .failed = value { self?.closed = true }
        } }
        listener.newConnectionHandler = { [weak self] connection in Task { @MainActor [weak self] in self?.accept(connection) } }
        listener.start(queue: .main)
        for _ in 0..<200 {
            try Task.checkCancellation(); guard !closed else { throw ConnectorError.authorization }
            if ready, let port = listener.port {
                let url = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth/callback")!; callbackURL = url; return url
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ConnectorError.authorization
    }
    func code() async throws -> String {
        let deadline = Date().addingTimeInterval(300)
        while receivedCode == nil {
            try Task.checkCancellation(); guard !closed, !denied, Date() < deadline else { throw ConnectorError.authorization }
            try await Task.sleep(for: .milliseconds(100))
        }
        return receivedCode!
    }
    private func accept(_ connection: NWConnection) {
        guard !closed, connections.count < 8 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection; connection.start(queue: .main)
        read(connection, id: id, buffer: Data())
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5)); self?.connections.removeValue(forKey: id)?.cancel()
        }
    }
    private func read(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { connection.cancel(); return }
                var buffer = buffer; if let data { buffer.append(data) }
                guard buffer.count <= 8192, error == nil else { self.connections.removeValue(forKey: id)?.cancel(); return }
                if let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") { self.finish(connection, id: id, request: text) }
                else if !complete { self.read(connection, id: id, buffer: buffer) }
                else { self.connections.removeValue(forKey: id)?.cancel() }
            }
        }
    }
    private func finish(_ connection: NWConnection, id: UUID, request: String) {
        let lines = request.components(separatedBy: "\r\n")
        let words = (lines.first ?? "").split(separator: " ")
        var accepted = false
        if words.count == 3, words[0] == "GET", let callbackURL,
           lines.contains(where: { $0.lowercased() == "host: 127.0.0.1:\(callbackURL.port!)" }),
           let url = URL(string: String(words[1]), relativeTo: callbackURL)?.absoluteURL,
           MCPRemoteProtocol.sameOrigin(url, callbackURL), url.path == callbackURL.path,
           let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           items.filter({ $0.name == "state" }).count == 1, items.first(where: { $0.name == "state" })?.value == state {
            if items.contains(where: { $0.name == "error" }) { denied = true; accepted = true }
            else if items.filter({ $0.name == "code" }).count == 1, let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty, code.count < 4096 {
                receivedCode = code; accepted = true
            }
        }
        let body = accepted ? "You can return to Bobb. Puoi tornare a Bobb." : "Invalid callback."
        let response = "HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n" + body
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in self?.connections.removeValue(forKey: id)?.cancel() }
        })
    }
    func close() { closed = true; listener?.cancel(); listener = nil; connections.values.forEach { $0.cancel() }; connections.removeAll() }
}
