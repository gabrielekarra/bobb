import AppKit
import SQLite3
import BobbCore

/// Model-free integration checks use disposable files/database and a loopback
/// fixture. They never read the user's Messages database or send a real message.
@MainActor
func runIntegrationSmokeCheck() {
    Task { @MainActor in
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bobb-integrations-" + UUID().uuidString)
        let process = Process()
        var outcome: Int32 = 0
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            func require(_ value: Bool, _ label: String) throws { if !value { throw NativeAppTools.Failure.unavailable(label) } }
            func tool(_ id: String) -> AppTool { NativeAppToolCatalog.tools.first { $0.id == id }! }
            let bookmark = try root.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            let folder = FileFolder(name: "Fixture", bookmark: bookmark)
            var grants = [folder]
            let files = FileAppTools(folders: { grants })
            let created = try files.execute(tool("files.create"), ["folder_id": .string(folder.id), "path": "note.txt", "text": "hello"])
            let id = created["file"]!["file_id"]!
            let receipt = try files.execute(tool("files.read"), ["file_id": id])
            try require(receipt["text"] == .string("hello"), "file readback")
            let changed = try files.execute(tool("files.replace"), ["file_id": id, "expected_version": receipt["file"]!["version"]!, "text": "updated"])
            try require(changed["status"] == .string("updated"), "file replacement")
            try "{\\rtf1\\ansi Native rich text}".write(to: root.appendingPathComponent("sample.rtf"), atomically: true, encoding: .utf8)
            try require(try FileAppTools.text(root.appendingPathComponent("sample.rtf")).contains("Native rich text"), "RTF extraction")
            grants.removeAll()
            do { _ = try files.execute(tool("files.read"), ["file_id": id]); throw NativeAppTools.Failure.unavailable("revoked folder was read") }
            catch { try require(String(describing: error) != "revoked folder was read", "folder revocation") }
            let dbURL = root.appendingPathComponent("messages.db")
            var db: OpaquePointer?
            guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else { throw ConnectorError.response }
            let sql = """
            CREATE TABLE chat(guid TEXT, display_name TEXT, service_name TEXT);
            CREATE TABLE handle(id TEXT);
            CREATE TABLE chat_handle_join(chat_id INTEGER,handle_id INTEGER);
            CREATE TABLE message(text TEXT,is_from_me INTEGER,date INTEGER,cache_has_attachments INTEGER,attributedBody BLOB,handle_id INTEGER);
            CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);
            CREATE TABLE attachment(guid TEXT,filename TEXT,transfer_name TEXT,mime_type TEXT,total_bytes INTEGER);
            CREATE TABLE message_attachment_join(message_id INTEGER,attachment_id INTEGER);
            INSERT INTO chat VALUES('fixture-group','Fixture group','iMessage');
            INSERT INTO handle VALUES('alice@example.invalid'),('bob@example.invalid');
            INSERT INTO chat_handle_join VALUES(1,1),(1,2);
            INSERT INTO message VALUES('fixture text',0,0,0,NULL,1);
            INSERT INTO chat_message_join VALUES(1,1);
            """
            let status = sqlite3_exec(db, sql, nil, nil, nil); sqlite3_close(db)
            try require(status == SQLITE_OK, "messages fixture")
            let messages = MessageAppTools(databaseURL: dbURL)
            let chats = try messages.execute(tool("messages.list"), [:])
            try require(chats["items"]?.arrayValue?.first?["group"] == .bool(true), "group discovery")
            let chatID = chats["items"]!.arrayValue!.first!["chat_id"]!
            let content = try messages.execute(tool("messages.read"), ["chat_id": chatID])
            try require(content["items"]?.arrayValue?.first?["text"] == .string("fixture text"), "group text")
            do { _ = try messages.execute(tool("messages.send"), ["chat_id": chatID, "members": ["wrong@example.invalid"], "body": "never send"]); throw ConnectorError.response }
            catch { try require(String(describing: error).contains("complete exact"), "recipient mismatch blocked") }
            guard let fixtureIndex = CommandLine.arguments.firstIndex(of: "--check-integrations"), CommandLine.arguments.count > fixtureIndex + 1 else { throw ConnectorError.configuration }
            let fixture = CommandLine.arguments[fixtureIndex + 1]
            let portFile = root.appendingPathComponent("port")
            process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BOBB_TEST_PYTHON"] ?? "/usr/bin/python3")
            process.arguments = [fixture, portFile.path]
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); defer { if process.isRunning { process.terminate() } }
            var port: Int?
            for _ in 0..<200 {
                port = (try? String(contentsOf: portFile, encoding: .utf8)).flatMap { Int($0) }
                if port != nil { break }; try await Task.sleep(for: .milliseconds(25))
            }
            guard let port else { throw ConnectorError.response }
            let origin = "http://127.0.0.1:\(port)"
            for (path, transport) in [("/mcp", MCPTransportKind.http), ("/stream", .http), ("/legacy", .sse), ("/fallback", .http)] {
                let connection = MCPConnection(configuration: MCPConfiguration(id: "fixture", executable: "", enabled: true, excludedTools: ["delayed"], transport: transport, endpoint: origin + path))
                defer { connection.disconnect() }
                try await connection.connect(); try require(connection.tools.count == 1, "pagination/exclusion " + path)
                let result = try await connection.call(name: "echo", arguments: ["sentinel": "local-only"])
                try require(result["structuredContent"]?["sentinel"] == .string("local-only"), "transport " + path)
            }
            for path in ["/unauthorized", "/redirect"] {
                let connection = MCPConnection(configuration: MCPConfiguration(id: "fixture", executable: "", enabled: true, transport: .http, endpoint: origin + path))
                do { try await connection.connect(); throw NativeAppTools.Failure.unavailable("unexpected success") }
                catch { try require(String(describing: error) != "unexpected success", "unauthorized/redirect") }
                connection.disconnect()
            }
            let staged = MCPComputer(configuration: MCPConfiguration(id: "fixture", executable: "", enabled: true, excludedTools: ["delayed"], transport: .http, endpoint: origin + "/mcp"), goal: "echo", enabled: { true })
            _ = await staged.observe()
            try require(await staged.perform(.press(key: 0)) == .ok, "MCP tool selection")
            try require(await staged.perform(.type(key: -2, text: #"{"sentinel":"prepared"}"#, submit: false)) == .ok, "MCP argument preparation")
            try require(await staged.perform(.press(key: -3)) == .ok, "MCP staged invocation")
            let stagedResult = await staged.observe()
            try require(stagedResult?.screenText.contains("prepared") == true, "MCP result observation")
            await staged.close()
            let delayed = MCPConnection(configuration: MCPConfiguration(id: "fixture", executable: "", enabled: true, transport: .http, endpoint: origin + "/mcp"))
            try await delayed.connect()
            let request = Task { try await delayed.call(name: "delayed", arguments: [:]) }
            try await Task.sleep(for: .milliseconds(100)); let start = Date(); request.cancel()
            do { _ = try await request.value; throw ConnectorError.response } catch is CancellationError {} catch { throw error }
            try require(Date().timeIntervalSince(start) < 2, "request cancellation"); delayed.disconnect()
            let oauth = MCPConfiguration(id: "fixture-oauth", executable: "", enabled: true, transport: .http, endpoint: origin + "/oauth/mcp", oauth: MCPOAuthConfiguration())
            defer { MCPOAuth.logout(oauth) }
            try await MCPOAuth.login(oauth) { url in
                do { _ = try await URLSession.shared.data(from: url); return true } catch { return false }
            }
            let authenticated = MCPConnection(configuration: oauth); defer { authenticated.disconnect() }
            try await authenticated.connect(); try require(authenticated.tools.count == 2, "OAuth PKCE and refresh")
            print("Integration checks passed: files, messages, HTTP/SSE, OAuth, cancellation.")
        } catch {
            if process.isRunning { process.terminate() }
            print("Integration check failed: \(error)"); outcome = 1
        }
        exit(outcome)
    }
}
