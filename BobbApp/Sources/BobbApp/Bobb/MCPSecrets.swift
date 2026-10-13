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
    static func environment(_ configuration: MCPConfiguration) throws -> [String: String] {
        var result: [String: String] = [:]
        for (key, account) in configuration.environmentReferences {
            guard MCPImportedServer.allowedEnvironmentKey(key) else { throw ConnectorError.configuration }
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var data: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &data) == errSecSuccess, let raw = data as? Data,
                  let value = String(data: raw, encoding: .utf8) else { throw ConnectorError.configuration }
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
                guard !entry.command.contains("\0"), let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw ConnectorError.configuration }
                var environment: [String: String] = [:]
                for key in entry.env.keys.sorted() {
                    let account = try store(entry.env[key]!); references.append(account); environment[key] = account
                }
                return MCPConfiguration(id: id, executable: path, arguments: entry.args, environmentReferences: environment,
                    excludedTools: entry.excludedTools, workingDirectory: entry.workingDirectory)
            }
        } catch { references.forEach(remove); throw error }
    }
}
