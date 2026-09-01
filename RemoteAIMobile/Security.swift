import Foundation
import Security
import CryptoKit

final class KeychainStore {
    static let shared = KeychainStore()
    private let service = "com.remoteai.mobile.pairing"
    func save(_ data: Data, account: String) throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q; add[kSecValueData as String] = data
        let s = SecItemAdd(add as CFDictionary, nil)
        guard s == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(s)) }
    }
    func load(account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    func delete(account: String) { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary) }
}

struct EncryptedEnvelope: Codable { let nonce: Data; let ciphertext: Data; let tag: Data }

enum PayloadCrypto {
    static func encrypt(_ plaintext: Data, keyData: Data) throws -> EncryptedEnvelope {
        let key = SymmetricKey(data: keyData)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        let nonce = sealed.nonce.withUnsafeBytes { Data($0) }
        return EncryptedEnvelope(nonce: nonce, ciphertext: sealed.ciphertext, tag: sealed.tag)
    }
    static func decrypt(_ envelope: EncryptedEnvelope, keyData: Data) throws -> Data {
        let nonce = try AES.GCM.Nonce(data: envelope.nonce)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: envelope.ciphertext, tag: envelope.tag)
        return try AES.GCM.open(box, using: SymmetricKey(data: keyData))
    }
    static func mockPairingKey(code: String, machineId: String) -> Data {
        let input = SymmetricKey(data: Data(code.utf8))
        let salt = Data(machineId.utf8)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: salt, info: Data("RemoteAI pairing v1".utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }
}

struct PairingResponse: Codable { let machineId: String; let sharedSecretBase64: String }

final class PairingClient {
    func pair(baseURL: URL, code: String) async throws -> PairingResponse {
        if baseURL.host?.hasSuffix("invalid") == true {
            return PairingResponse(machineId: "my-pc", sharedSecretBase64: PayloadCrypto.mockPairingKey(code: code, machineId: "my-pc").base64EncodedString())
        }
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/pair")); req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["pairingCode": code])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw TransportError.pairingRequired }
        return try JSONDecoder.remoteAI.decode(PairingResponse.self, from: data)
    }
}

extension JSONEncoder { static let remoteAI: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }() }
extension JSONDecoder { static let remoteAI: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }() }
