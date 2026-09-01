import Foundation
import Security
import CryptoKit

final class KeychainStore {
    static let shared = KeychainStore()
    private let service = "com.remoteai.mobile.pairing"

    func save(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func delete(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }
}

enum PairingKeyStore {
    private static let deviceIdAccount = "device-id-v1"
    private static func privateAccount(_ machineId: String) -> String { "x25519-private-v1.\(machineId)" }
    private static func sharedAccount(_ machineId: String) -> String { "shared-key-v1.\(machineId)" }

    static func deviceId(keychain: KeychainStore = .shared) throws -> String {
        if let data = keychain.load(account: deviceIdAccount), let id = String(data: data, encoding: .utf8), !id.isEmpty { return id }
        let id = "ios-\(UUID().uuidString.lowercased())"
        try keychain.save(Data(id.utf8), account: deviceIdAccount)
        return id
    }

    static func savePairing(machineId: String, privateKeyRaw: Data, sharedKey: Data, keychain: KeychainStore = .shared) throws {
        try keychain.save(privateKeyRaw, account: privateAccount(machineId))
        try keychain.save(sharedKey, account: sharedAccount(machineId))
    }

    static func sharedKey(machineId: String, keychain: KeychainStore = .shared) -> Data? {
        keychain.load(account: sharedAccount(machineId))
    }

    static func privateKey(machineId: String, keychain: KeychainStore = .shared) -> Data? {
        keychain.load(account: privateAccount(machineId))
    }

    static func isPaired(machineId: String, keychain: KeychainStore = .shared) -> Bool {
        sharedKey(machineId: machineId, keychain: keychain)?.count == 32
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}

enum PayloadCrypto {
    private static let x25519SPKIPrefix = Data([0x30,0x2a,0x30,0x05,0x06,0x03,0x2b,0x65,0x6e,0x03,0x21,0x00])

    static func generateDevicePrivateKey() -> Data {
        Curve25519.KeyAgreement.PrivateKey().rawRepresentation
    }

    static func publicKeySPKIBase64(privateKeyRaw: Data) throws -> String {
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyRaw)
        var der = x25519SPKIPrefix
        der.append(privateKey.publicKey.rawRepresentation)
        return der.base64EncodedString()
    }

    static func parseX25519SPKI(_ base64: String) throws -> Curve25519.KeyAgreement.PublicKey {
        guard let der = Data(base64Encoded: base64), der.count == x25519SPKIPrefix.count + 32,
              der.prefix(x25519SPKIPrefix.count) == x25519SPKIPrefix else { throw TransportError.malformedData }
        return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: der.suffix(32))
    }

    static func pairingProof(pairingCode: String, challenge: String, machineId: String, deviceId: String, devicePublicKeyB64: String) -> String {
        let key = SymmetricKey(data: Data(pairingCode.utf8))
        let input = Data("\(challenge)|\(machineId)|\(deviceId)|\(devicePublicKeyB64)".utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: input, using: key)
        return Base64URL.encode(Data(mac))
    }

    static func deriveSharedKey(privateKeyRaw: Data, machinePublicKeyB64: String, machineId: String, deviceId: String) throws -> Data {
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyRaw)
        let peer = try parseX25519SPKI(machinePublicKeyB64)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let key = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("RemoteAI:\(machineId)".utf8),
            sharedInfo: Data("device:\(deviceId):protocol-v1".utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    static func encrypt(_ plaintext: Data, keyData: Data, machineId: String, deviceId: String, messageId: String) throws -> EncryptedRelayBody {
        guard keyData.count == 32 else { throw TransportError.pairingRequired }
        let aad = Data("\(machineId)|\(deviceId)|\(messageId)|v1".utf8)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: keyData), authenticating: aad)
        return EncryptedRelayBody(
            alg: "A256GCM",
            nonce: Base64URL.encode(sealed.nonce.withUnsafeBytes { Data($0) }),
            ciphertext: Base64URL.encode(sealed.ciphertext),
            tag: Base64URL.encode(sealed.tag)
        )
    }

    static func decrypt(_ body: EncryptedRelayBody, keyData: Data, machineId: String, deviceId: String, messageId: String) throws -> Data {
        guard body.alg == "A256GCM", keyData.count == 32,
              let nonceData = Base64URL.decode(body.nonce), nonceData.count == 12,
              let ciphertext = Base64URL.decode(body.ciphertext),
              let tag = Base64URL.decode(body.tag), tag.count == 16 else { throw TransportError.malformedData }
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let aad = Data("\(machineId)|\(deviceId)|\(messageId)|v1".utf8)
        return try AES.GCM.open(box, using: SymmetricKey(data: keyData), authenticating: aad)
    }
}

struct PairingResult {
    let machineId: String
    let deviceId: String
}

final class RelayPairingClient {
    private let session: URLSession
    private let keychain: KeychainStore
    private let maxFrameBytes = 512 * 1024

    init(session: URLSession = .shared, keychain: KeychainStore = .shared) {
        self.session = session
        self.keychain = keychain
    }

    func pair(baseURL: URL, machineId: String, pairingCode: String, label: String = "iPhone") async throws -> PairingResult {
        try RemoteAIConfig.validateSecureRelay(baseURL)
        guard !machineId.isEmpty, machineId.count <= 160,
              pairingCode.count == 8, pairingCode.allSatisfy({ $0.isNumber }) else { throw TransportError.malformedData }

        let deviceId = try PairingKeyStore.deviceId(keychain: keychain)
        let privateKeyRaw = PayloadCrypto.generateDevicePrivateKey()
        let publicKeyB64 = try PayloadCrypto.publicKeySPKIBase64(privateKeyRaw: privateKeyRaw)
        let socket = session.webSocketTask(with: try RemoteAIConfig.deviceWebSocketURL(baseURL: baseURL, machineId: machineId, deviceId: deviceId), protocols: ["remoteai.v1"])
        socket.resume()
        do {
            try await ping(socket)
            try await send(frame: RelayFrame(v: 1, kind: "PAIR_REQUEST", machineId: machineId, deviceId: deviceId, messageId: UUID().uuidString, body: [
                "devicePublicKeyB64": .string(publicKeyB64),
                "label": .string(String(label.prefix(80)))
            ]), socket: socket)

            let challenge = try await receiveFrame(kind: "PAIR_CHALLENGE", deviceId: deviceId, socket: socket)
            guard let challengeValue = challenge.body["challenge"]?.stringValue,
                  let challengeMachinePublic = challenge.body["machinePublicKeyB64"]?.stringValue else { throw TransportError.malformedData }
            let proof = PayloadCrypto.pairingProof(pairingCode: pairingCode, challenge: challengeValue, machineId: machineId, deviceId: deviceId, devicePublicKeyB64: publicKeyB64)
            try await send(frame: RelayFrame(v: 1, kind: "PAIR_PROOF", machineId: machineId, deviceId: deviceId, messageId: UUID().uuidString, body: ["proof": .string(proof)]), socket: socket)

            let accepted = try await receiveFrame(kind: "PAIR_ACCEPT", deviceId: deviceId, socket: socket)
            let machinePublicKeyB64 = accepted.body["machinePublicKeyB64"]?.stringValue ?? challengeMachinePublic
            let shared = try PayloadCrypto.deriveSharedKey(privateKeyRaw: privateKeyRaw, machinePublicKeyB64: machinePublicKeyB64, machineId: machineId, deviceId: deviceId)
            try PairingKeyStore.savePairing(machineId: machineId, privateKeyRaw: privateKeyRaw, sharedKey: shared, keychain: keychain)
            socket.cancel(with: .normalClosure, reason: nil)
            return PairingResult(machineId: machineId, deviceId: deviceId)
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
            throw error
        }
    }

    private func send(frame: RelayFrame, socket: URLSessionWebSocketTask) async throws {
        let data = try JSONEncoder.remoteAI.encode(frame)
        guard data.count <= 256 * 1024 else { throw TransportError.frameTooLarge }
        try await socket.send(.data(data))
    }

    private func receiveFrame(kind: String, deviceId: String, socket: URLSessionWebSocketTask) async throws -> RelayFrame {
        for _ in 0..<12 {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case .data(let value): data = value
            case .string(let value): data = Data(value.utf8)
            @unknown default: continue
            }
            guard data.count <= maxFrameBytes else { throw TransportError.frameTooLarge }
            let frame = try JSONDecoder.remoteAI.decode(RelayFrame.self, from: data)
            if frame.kind == "ACK", frame.body["error"]?.stringValue != nil { throw TransportError.pairingRequired }
            if frame.kind == kind, frame.deviceId == deviceId { return frame }
        }
        throw TransportError.timeout
    }

    private func ping(_ socket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }
}

enum RemoteAIDate {
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

extension JSONEncoder {
    static let remoteAI: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(RemoteAIDate.string(date))
        }
        return encoder
    }()
}

extension JSONDecoder {
    static let remoteAI: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = RemoteAIDate.parse(value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid RemoteAI ISO-8601 timestamp")
            }
            return date
        }
        return decoder
    }()
}
