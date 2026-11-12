import Foundation
import Security

// Stores desktop Web access passwords and CLIProxyAPI tunnel API keys in the keychain.
enum KeychainStore {
    private static let passwordService = "me.router-for.CodingProfessionalAgent.desktop-password"
    private static let tunnelAPIKeyService = "me.router-for.CodingProfessionalAgent.tunnel-api-key"
    private static let lastTunnelAPIKeyAccount = "default-last-tunnel-api-key"

    static func password(for id: UUID) -> String? {
        readSecret(service: passwordService, account: id.uuidString)
    }

    static func setPassword(_ password: String, for id: UUID) {
        writeSecret(password, service: passwordService, account: id.uuidString)
    }

    static func deletePassword(for id: UUID) {
        deleteSecret(service: passwordService, account: id.uuidString)
    }

    static func tunnelAPIKey(for id: UUID) -> String? {
        readSecret(service: tunnelAPIKeyService, account: id.uuidString)
    }

    static func setTunnelAPIKey(_ apiKey: String, for id: UUID) {
        writeSecret(apiKey, service: tunnelAPIKeyService, account: id.uuidString)
    }

    static func deleteTunnelAPIKey(for id: UUID) {
        deleteSecret(service: tunnelAPIKeyService, account: id.uuidString)
    }

    static func lastTunnelAPIKey() -> String? {
        readSecret(service: tunnelAPIKeyService, account: lastTunnelAPIKeyAccount)
    }

    static func setLastTunnelAPIKey(_ apiKey: String) {
        writeSecret(apiKey, service: tunnelAPIKeyService, account: lastTunnelAPIKeyAccount)
    }

    private static func readSecret(service: String, account: String) -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func writeSecret(_ value: String, service: String, account: String) {
        deleteSecret(service: service, account: account)
        guard !value.isEmpty else { return }
        var query = baseQuery(service: service, account: account)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func deleteSecret(service: String, account: String) {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
