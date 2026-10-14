import AppKit
import Security
import BobbCore

enum MCPSecrets {
    private static let service = "com.bobb.mcp-environment"
    static func store(_ value: String) throws -> String {
        let account = UUID().uuidString
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw ConnectorError.configuration }
        return account
    }
    static func remove(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }
    static func read(_ account: String) throws -> String {
        var data: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &data) == errSecSuccess, let raw = data as? Data,
              let value = String(data: raw, encoding: .utf8) else { throw ConnectorError.configuration }
        return value
    }
    static func replace(_ account: String, value: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query; entry[kSecValueData as String] = Data(value.utf8)
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw ConnectorError.configuration }
        } else if status != errSecSuccess { throw ConnectorError.configuration }
    }
    static func headers(_ configuration: MCPConfiguration) throws -> [String: String] {
        var result: [String: String] = [:]
        for (key, account) in configuration.headerReferences {
            let value = try read(account)
            guard MCPRemoteProtocol.allowedHeader(key, value: value) else { throw ConnectorError.configuration }
            result[key] = value
        }
        return result
    }
    static func environment(_ configuration: MCPConfiguration) throws -> [String: String] {
        var result: [String: String] = [:]
        for (key, account) in configuration.environmentReferences {
            guard MCPImportedServer.allowedEnvironmentKey(key) else { throw ConnectorError.configuration }
            let value = try read(account)
            result[key] = value
        }
        return result
    }
    /// Imported connectors remain disabled until the user reviews/enables them.
    static func imported(_ data: Data) throws -> [MCPConfiguration] {
        let entries = try MCPImportedServer.parse(data)
        var references: [String] = []
        do {
            return try entries.keys.sorted().map { id in
                let entry = entries[id]!
                let candidates = entry.command.hasPrefix("/") ? [entry.command]
                    : ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].map { $0 + "/" + entry.command }
                let path: String
                if entry.transport == .stdio {
                    guard !entry.command.contains("\0"), let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw ConnectorError.configuration }
                    path = found
                } else { path = "" }
                var environment: [String: String] = [:]
                for key in entry.env.keys.sorted() {
                    let account = try store(entry.env[key]!); references.append(account); environment[key] = account
                }
                var headers: [String: String] = [:]
                for key in entry.headers.keys.sorted() {
                    let account = try store(entry.headers[key]!); references.append(account); headers[key] = account
                }
                return MCPConfiguration(id: id, executable: path, arguments: entry.args, environmentReferences: environment,
                    excludedTools: entry.excludedTools, workingDirectory: entry.workingDirectory, transport: entry.transport, endpoint: entry.url, headerReferences: headers, oauth: entry.oauth)
            }
        } catch { references.forEach(remove); throw error }
    }
}
