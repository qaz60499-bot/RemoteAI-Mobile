import Foundation
import Security

public enum KeychainError: Error, LocalizedError, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    case invalidValue

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status): return "Keychain operation failed with status \(status)."
        case .invalidValue: return "The Keychain value is invalid."
        }
    }
}

public protocol PairingSecretStore: AnyObject {
    func read() throws -> Data?
    func save(_ secret: Data) throws
    func delete() throws
}

public final class KeychainStore: PairingSecretStore, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(service: String = "com.remoteai.mobile", account: String = "pairing-secret") {
        self.service = service
        self.account = account
    }

    public func read() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data else {
            throw KeychainError.invalidValue
        }
        return data
    }

    public func save(_ secret: Data) throws {
        var attributes: [String: Any] = [
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        attributes.merge(baseQuery()) { current, _ in current }
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public final class InMemorySecretStore: PairingSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?

    public init(value: Data? = nil) {
        self.value = value
    }

    public func read() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func save(_ secret: Data) throws {
        lock.lock()
        value = secret
        lock.unlock()
    }

    public func delete() throws {
        lock.lock()
        value = nil
        lock.unlock()
    }
}
