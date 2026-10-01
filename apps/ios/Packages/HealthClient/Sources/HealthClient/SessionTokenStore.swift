import Foundation
import Security

public protocol SessionTokenStore {
    func read() throws -> String?
    func save(_ token: String) throws
    func clear() throws
}

public enum SecureStorageError: Error { case unavailable }

public final class KeychainSessionStore: SessionTokenStore {
    private let service: String
    private let account = "server-session"
    public init(service: String = "com.example.backupclient.session") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
    public func read() throws -> String? {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data,
              let token = String(data: data, encoding: .utf8) else { throw SecureStorageError.unavailable }
        return token
    }
    public func save(_ token: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            for (key, value) in attributes { item[key] = value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw SecureStorageError.unavailable }
        } else if status != errSecSuccess { throw SecureStorageError.unavailable }
    }
    public func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecureStorageError.unavailable }
    }
}
