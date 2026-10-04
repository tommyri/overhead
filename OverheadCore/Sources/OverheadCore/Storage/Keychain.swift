import Foundation
import Security

/// Minimal generic-password Keychain wrapper. One item per (service, account).
public struct Keychain: Sendable {
    public let service: String
    /// Older service names this app used. An item found under one of them is moved to
    /// `service` the first time it is read, so renaming the app never loses credentials.
    public let legacyServices: [String]

    public init(service: String = "app.overhead", legacyServices: [String] = []) {
        self.service = service
        self.legacyServices = legacyServices
    }

    public enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let s):
                return (SecCopyErrorMessageString(s, nil) as String?) ?? "Keychain error \(s)"
            }
        }
    }

    private func baseQuery(account: String, service: String? = nil) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service ?? self.service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read(account: String) throws -> String? {
        if let value = try read(account: account, service: service) { return value }
        // Migrate from a previous service name, if present.
        for legacy in legacyServices {
            if let value = try read(account: account, service: legacy) {
                try write(account: account, value: value)
                try? delete(account: account, service: legacy)
                return value
            }
        }
        return nil
    }

    private func read(account: String, service: String) throws -> String? {
        var q = baseQuery(account: account, service: service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func write(account: String, value: String) throws {
        let data = Data(value.utf8)
        let q = baseQuery(account: account)
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func delete(account: String) throws {
        try delete(account: account, service: service)
        for legacy in legacyServices { try? delete(account: account, service: legacy) }
    }

    private func delete(account: String, service: String) throws {
        let status = SecItemDelete(baseQuery(account: account, service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
