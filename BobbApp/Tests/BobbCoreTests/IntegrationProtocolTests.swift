import Foundation
import Testing
@testable import BobbCore

@Suite struct IntegrationProtocolTests {
    @Test func remoteImportAndOriginsRejectUnsafeCredentialsAndURLs() throws {
        let entries = try MCPImportedServer.parse(Data(#"{"mcpServers":{"remote":{"url":"https://service.example/mcp","headers":{"Authorization":"Bearer example"},"oauth":{"clientId":"bobb"}},"legacy":{"type":"sse","url":"http://127.0.0.1:4321/sse"}}}"#.utf8))
        #expect(entries["remote"]?.transport == .http)
        #expect(entries["remote"]?.headers["Authorization"] == "Bearer example")
        #expect(entries["legacy"]?.transport == .sse)
        for url in ["http://service.example/mcp", "https://user:password@service.example/mcp", "file:///tmp/x", "https://service.example/#fragment"] { #expect(MCPRemoteProtocol.endpoint(url) == nil) }
        for name in ["Host", "Cookie", "Accept", "MCP-Session-Id", "Bad Key"] { #expect(!MCPRemoteProtocol.allowedHeader(name, value: "x")) }
        #expect(!MCPRemoteProtocol.allowedHeader("Authorization", value: "Bearer x\r\nX: y"))
        #expect(throws: (any Error).self) { try MCPImportedServer.parse(Data(#"{"mcpServers":{"x":{"url":"https://service.example/mcp","headers":{"Host":"other.example"}}}}"#.utf8)) }
        #expect(!MCPRemoteProtocol.sameOrigin(URL(string: "https://service.example/mcp")!, URL(string: "https://service.example:8443/mcp")!))
    }
    @Test func discoveryHandlesPathIssuersAndFormEncoding() {
        #expect(MCPRemoteProtocol.authorizationMetadataURLs(URL(string: "https://auth.example/tenant")!).map(\.absoluteString) == [
            "https://auth.example/.well-known/oauth-authorization-server/tenant", "https://auth.example/.well-known/openid-configuration/tenant", "https://auth.example/tenant/.well-known/openid-configuration"])
        #expect(MCPRemoteProtocol.protectedMetadataURLs(URL(string: "https://service.example/mcp")!).first?.path == "/.well-known/oauth-protected-resource/mcp")
        let form = String(decoding: MCPRemoteProtocol.form(["code": "a+b&c=d", "scope": "read write"]), as: UTF8.self)
        #expect(form.contains("a%2Bb%26c%3Dd")); #expect(form.contains("read%20write"))
    }
    @Test func SSEHandlesCommentsCRLFMultilineAndBounds() throws {
        var decoder = SSEDecoder()
        #expect(try decoder.line(": keepalive") == nil)
        _ = try decoder.line("id: abc\r"); _ = try decoder.line("event: endpoint"); _ = try decoder.line("data: /messages")
        #expect(try decoder.line("") == ServerSentEvent(event: "endpoint", data: "/messages", id: "abc"))
        _ = try decoder.line("data: one"); _ = try decoder.line("data: two")
        #expect(try decoder.line("")?.data == "one\ntwo")
        #expect(throws: (any Error).self) { try decoder.line(String(repeating: "x", count: 1_000_001)) }
    }
    @Test func foldersCannotEscapeThroughTraversalPrefixOrSymlink() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = temp.appendingPathComponent("allowed"), outside = temp.appendingPathComponent("allowed-other")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        #expect(FileScope.resolve("notes/new.txt", root: root)?.path == root.appendingPathComponent("notes/new.txt").path)
        for path in ["../allowed-other/secret.txt", "escape/secret.txt", "/etc/passwd", "a\0b"] { #expect(FileScope.resolve(path, root: root) == nil) }
    }
    @Test func archivedTextIsBoundedAndDoesNotBecomeACommand() {
        let text = "A modern message"
        var data = Data([4,11]); data.append(Data("streamtyped".utf8)); data.append(contentsOf: [0x84,1,0x2b,UInt8(text.utf8.count)]); data.append(Data(text.utf8))
        #expect(MessagesCommandDecoder.archivedStrings(data) == [text])
        #expect(MessagesCommandDecoder.decode(plain: nil, attributedBody: data) == nil)
        #expect(MessagesCommandDecoder.archivedStrings(Data(repeating: 0, count: 65537)).isEmpty)
    }
    @Test func settingsMigrateAndPreserveFoldersAndRemoteFields() throws {
        let old = try JSONDecoder().decode(MCPConfiguration.self, from: Data(#"{"id":"x","executable":"/usr/bin/test"}"#.utf8))
        #expect(old.transport == .stdio); #expect(old.endpoint == nil)
        var settings = BobbWorkspaceSettings()
        settings.fileFolders = [FileFolder(name: "Documents", bookmark: Data([1,2,3]))]
        settings.connectors = [MCPConfiguration(id: "remote", executable: "", transport: .http, endpoint: "https://service.example/mcp")]
        #expect(try JSONDecoder().decode(BobbWorkspaceSettings.self, from: JSONEncoder().encode(settings)) == settings)
        var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        encoded.removeValue(forKey: "fileFolders")
        #expect(try JSONDecoder().decode(BobbWorkspaceSettings.self, from: JSONSerialization.data(withJSONObject: encoded)).fileFolders == nil)
    }
}
