import Foundation

public enum MCPRemoteProtocol {
    /// HTTPS, or HTTP to an explicitly configured native loopback service.
    public static func endpoint(_ text: String) -> URL? {
        guard text.utf8.count <= 4096, let url = URL(string: text), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)) else { return nil }
        return url
    }
    public static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme == b.scheme && a.host?.lowercased() == b.host?.lowercased()
            && (a.port ?? (a.scheme == "https" ? 443 : 80)) == (b.port ?? (b.scheme == "https" ? 443 : 80))
    }
    public static func allowedHeader(_ key: String, value: String) -> Bool {
        let reserved = ["host", "content-length", "content-type", "accept", "connection", "cookie", "mcp-session-id", "mcp-protocol-version"]
        return !key.isEmpty && key.count <= 100 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            && !reserved.contains(key.lowercased()) && value.utf8.count <= 16_000 && !value.contains(where: { $0.isNewline || $0 == "\0" })
    }
    public static func form(_ fields: [String: String]) -> Data {
        var parts = URLComponents(); parts.queryItems = fields.keys.sorted().map { URLQueryItem(name: $0, value: fields[$0]) }
        return Data((parts.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }
    public static func protectedMetadataURLs(_ resource: URL) -> [URL] {
        var base = URLComponents(url: resource, resolvingAgainstBaseURL: false)!
        base.query = nil; base.fragment = nil
        let path = base.path
        base.path = "/.well-known/oauth-protected-resource" + (path == "/" ? "" : path)
        let first = base.url!
        base.path = "/.well-known/oauth-protected-resource"
        return first == base.url! ? [first] : [first, base.url!]
    }
    public static func authorizationMetadataURLs(_ issuer: URL) -> [URL] {
        var parts = URLComponents(url: issuer, resolvingAgainstBaseURL: false)!
        let path = parts.path == "/" ? "" : parts.path
        parts.path = "/.well-known/oauth-authorization-server" + path; let oauth = parts.url!
        parts.path = "/.well-known/openid-configuration" + path; let oidc = parts.url!
        parts.path = path + "/.well-known/openid-configuration"
        return [oauth, oidc, parts.url!]
    }
}

public struct ServerSentEvent: Sendable, Equatable {
    public var event: String
    public var data: String
    public var id: String?
}
/// SSE lines from URLSession.AsyncBytes; bounded even for an uncooperative peer.
public struct SSEDecoder: Sendable {
    private var event = "message", data: [String] = [], id: String?, size = 0
    public init() {}
    public mutating func line(_ raw: String) throws -> ServerSentEvent? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        size += line.utf8.count
        guard size <= 1_000_000 else { throw CocoaError(.fileReadTooLarge) }
        if line.isEmpty {
            let result = data.isEmpty ? nil : ServerSentEvent(event: event, data: data.joined(separator: "\n"), id: id)
            event = "message"; data.removeAll(); size = 0
            return result
        }
        if line.hasPrefix(":") { return nil }
        let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var value = pair.count == 2 ? String(pair[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch pair[0] {
        case "event": event = value
        case "data": data.append(value)
        case "id": if !value.contains("\0") { id = value }
        default: break
        }
        return nil
    }
}
