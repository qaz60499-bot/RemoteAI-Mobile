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
    private static func legacyPrivateAccount(_ machineId: String) -> String { "x25519-private-v1.\(machineId)" }
    private static func sharedAccount(_ machineId: String) -> String { "shared-key-v1.\(machineId)" }

    static func deviceId(keychain: KeychainStore = .shared) throws -> String {
        if let data = keychain.load(account: deviceIdAccount), let id = String(data: data, encoding: .utf8), !id.isEmpty { return id }
        let id = "ios-\(UUID().uuidString.lowercased())"
        try keychain.save(Data(id.utf8), account: deviceIdAccount)
        return id
    }

    static func savePairing(machineId: String, sharedKey: Data, keychain: KeychainStore = .shared) throws {
        guard sharedKey.count == 32 else { throw TransportError.malformedData }
        try keychain.save(sharedKey, account: sharedAccount(machineId))
        // Migration cleanup: protocol-v1 originally persisted the ephemeral X25519 private key.
        // Transport only needs the derived shared key after pairing, so remove any legacy copy.
        keychain.delete(account: legacyPrivateAccount(machineId))
    }

    static func sharedKey(machineId: String, keychain: KeychainStore = .shared) -> Data? {
        keychain.load(account: sharedAccount(machineId))
    }

    static func deletePairing(machineId: String, keychain: KeychainStore = .shared) {
        keychain.delete(account: sharedAccount(machineId))
        keychain.delete(account: legacyPrivateAccount(machineId))
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
        let bytes = Array(value.utf8)
        guard !value.contains("="),
              bytes.allSatisfy({ byte in
                  switch byte {
                  case 45, 48...57, 65...90, 95, 97...122: return true
                  default: return false
                  }
              }) else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let decoded = Data(base64Encoded: base64), encode(decoded) == value else { return nil }
        return decoded
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
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let aad = Data("\(machineId)|\(deviceId)|\(messageId)|v1".utf8)
            return try AES.GCM.open(box, using: SymmetricKey(data: keyData), authenticating: aad)
        } catch {
            throw TransportError.malformedData
        }
    }
}

protocol PairingWebSocket: AnyObject {
    func setMaximumMessageSize(_ bytes: Int)
    func resume()
    func cancel(code: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message, timeout: TimeInterval) async throws
    func receive(timeout: TimeInterval) async throws -> URLSessionWebSocketTask.Message
}

final class URLSessionPairingWebSocket: PairingWebSocket {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func setMaximumMessageSize(_ bytes: Int) { task.maximumMessageSize = bytes }
    func resume() { task.resume() }
    func cancel(code: URLSessionWebSocketTask.CloseCode, reason: Data?) { task.cancel(with: code, reason: reason) }
    func send(_ message: URLSessionWebSocketTask.Message, timeout: TimeInterval) async throws {
        try await WebSocketIO.send(message, on: task, timeout: timeout, timeoutReason: "pairing-send-timeout")
    }
    func receive(timeout: TimeInterval) async throws -> URLSessionWebSocketTask.Message {
        try await WebSocketIO.receive(from: task, timeout: timeout, timeoutReason: "pairing-receive-timeout")
    }
}

struct PairingResult {
    let machineId: String
    let deviceId: String
}

enum PairingStage: String, CaseIterable {
    case preparing
    case connectingRelay
    case relayConnected
    case sendingRequest
    case waitingChallenge
    case challengeReceived
    case verifyingWindowsKey
    case sendingProof
    case waitingApproval
    case secureKeySaved
    case connectingRemoteAI
    case loadingRuntimes
    case completed

    var title: String {
        switch self {
        case .preparing: return "Preparing secure pairing…"
        case .connectingRelay: return "Connecting to Relay…"
        case .relayConnected: return "Relay connected"
        case .sendingRequest: return "Sending pairing request…"
        case .waitingChallenge: return "Waiting for Windows challenge…"
        case .challengeReceived: return "Challenge received"
        case .verifyingWindowsKey: return "Verifying Windows key…"
        case .sendingProof: return "Sending pairing proof…"
        case .waitingApproval: return "Waiting for Windows approval…"
        case .secureKeySaved: return "Secure key saved"
        case .connectingRemoteAI: return "Connecting RemoteAI…"
        case .loadingRuntimes: return "Loading runtimes…"
        case .completed: return "Pairing complete"
        }
    }
}

struct PairingStepError: LocalizedError {
    let stage: PairingStage
    let underlying: Error

    var errorDescription: String? {
        "\(stage.title.replacingOccurrences(of: "…", with: "")): \(underlying.localizedDescription)"
    }
}

@MainActor
final class RelayPairingClient {
    private let keychain: KeychainStore
    private let socketFactory: (URL, [String]) -> PairingWebSocket
    private let maxFrameBytes = 512 * 1024
    private let totalTimeout: TimeInterval

    init(
        session: URLSession = .shared,
        keychain: KeychainStore = .shared,
        totalTimeout: TimeInterval = 20,
        socketFactory: ((URL, [String]) -> PairingWebSocket)? = nil
    ) {
        self.keychain = keychain
        self.totalTimeout = totalTimeout
        self.socketFactory = socketFactory ?? { url, protocols in
            URLSessionPairingWebSocket(task: session.webSocketTask(with: url, protocols: protocols))
        }
    }

    func pair(
        baseURL: URL,
        machineId: String,
        pairingCode: String,
        label: String = "iPhone",
        progress: (PairingStage) -> Void = { _ in }
    ) async throws -> PairingResult {
        var stage: PairingStage = .preparing
        func advance(_ next: PairingStage) {
            stage = next
            progress(next)
        }

        advance(.preparing)
        do {
            try RemoteAIConfig.validateSecureRelay(baseURL)
            try ProtocolSecurity.validateIdentifier(machineId)
            guard ProtocolSecurity.validatePairingCode(pairingCode) else { throw TransportError.malformedData }

            let deviceId = try PairingKeyStore.deviceId(keychain: keychain)
            try ProtocolSecurity.validateIdentifier(deviceId)
            let privateKeyRaw = PayloadCrypto.generateDevicePrivateKey()
            let publicKeyB64 = try PayloadCrypto.publicKeySPKIBase64(privateKeyRaw: privateKeyRaw)
            let url = try RemoteAIConfig.deviceWebSocketURL(baseURL: baseURL, machineId: machineId, deviceId: deviceId)
            let socket = socketFactory(url, ["remoteai.v1"])
            socket.setMaximumMessageSize(maxFrameBytes)
            let deadline = Date().addingTimeInterval(totalTimeout)

            advance(.connectingRelay)
            socket.resume()
            defer { socket.cancel(code: .normalClosure, reason: nil) }

            try await waitForRelayReady(machineId: machineId, deviceId: deviceId, socket: socket, deadline: deadline)
            advance(.relayConnected)

            advance(.sendingRequest)
            try await send(frame: RelayFrame(v: 1, kind: "PAIR_REQUEST", machineId: machineId, deviceId: deviceId, messageId: UUID().uuidString, body: [
                "devicePublicKeyB64": .string(publicKeyB64),
                "label": .string(String(label.prefix(80)))
            ]), socket: socket, deadline: deadline)

            advance(.waitingChallenge)
            let challenge = try await receiveFrame(kind: "PAIR_CHALLENGE", machineId: machineId, deviceId: deviceId, socket: socket, deadline: deadline)
            advance(.challengeReceived)
            guard let challengeValue = challenge.body["challenge"]?.stringValue,
                  !challengeValue.isEmpty,
                  challengeValue.utf8.count <= 512,
                  let challengeMachinePublic = challenge.body["machinePublicKeyB64"]?.stringValue else { throw TransportError.malformedData }

            advance(.verifyingWindowsKey)
            _ = try ProtocolSecurity.validatedPairingMachineKey(challengeKey: challengeMachinePublic, acceptedKey: nil)
            let proof = PayloadCrypto.pairingProof(pairingCode: pairingCode, challenge: challengeValue, machineId: machineId, deviceId: deviceId, devicePublicKeyB64: publicKeyB64)

            advance(.sendingProof)
            try await send(frame: RelayFrame(v: 1, kind: "PAIR_PROOF", machineId: machineId, deviceId: deviceId, messageId: UUID().uuidString, body: ["proof": .string(proof)]), socket: socket, deadline: deadline)

            advance(.waitingApproval)
            let accepted = try await receiveFrame(kind: "PAIR_ACCEPT", machineId: machineId, deviceId: deviceId, socket: socket, deadline: deadline)
            let machinePublicKeyB64 = try ProtocolSecurity.validatedPairingMachineKey(
                challengeKey: challengeMachinePublic,
                acceptedKey: accepted.body["machinePublicKeyB64"]?.stringValue
            )
            let shared = try PayloadCrypto.deriveSharedKey(privateKeyRaw: privateKeyRaw, machinePublicKeyB64: machinePublicKeyB64, machineId: machineId, deviceId: deviceId)
            try PairingKeyStore.savePairing(machineId: machineId, sharedKey: shared, keychain: keychain)
            advance(.secureKeySaved)
            return PairingResult(machineId: machineId, deviceId: deviceId)
        } catch {
            if let error = error as? PairingStepError { throw error }
            throw PairingStepError(stage: stage, underlying: error)
        }
    }

    private func remaining(until deadline: Date, cap: TimeInterval) throws -> TimeInterval {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw TransportError.timeout }
        return min(cap, remaining)
    }

    private func waitForRelayReady(machineId: String, deviceId: String, socket: PairingWebSocket, deadline: Date) async throws {
        for _ in 0..<4 {
            let message = try await socket.receive(timeout: try remaining(until: deadline, cap: 5))
            let data = WebSocketIO.data(from: message)
            guard !data.isEmpty else { continue }
            let frame = try ProtocolSecurity.decodeRelayFrame(data, maxBytes: maxFrameBytes)
            try ProtocolSecurity.validate(frame, expectedMachineId: machineId)
            guard frame.deviceId == nil || frame.deviceId == deviceId else { throw TransportError.malformedData }
            if let error = pairingAckError(frame) { throw error }
            if frame.kind == "ACK", frame.body["relay"]?.stringValue == "device-connected" {
                guard frame.deviceId == deviceId else { throw TransportError.malformedData }
                if frame.body["agentOnline"]?.boolValue == false { throw TransportError.offline }
                return
            }
        }
        throw TransportError.timeout
    }

    private func send(frame: RelayFrame, socket: PairingWebSocket, deadline: Date) async throws {
        let data = try JSONEncoder.remoteAI.encode(frame)
        guard data.count <= 256 * 1024 else { throw TransportError.frameTooLarge }
        try await socket.send(.data(data), timeout: try remaining(until: deadline, cap: 4))
    }

    private func receiveFrame(kind: String, machineId: String, deviceId: String, socket: PairingWebSocket, deadline: Date) async throws -> RelayFrame {
        for _ in 0..<12 {
            let message = try await socket.receive(timeout: try remaining(until: deadline, cap: 7))
            let data = WebSocketIO.data(from: message)
            guard !data.isEmpty else { continue }
            let frame = try ProtocolSecurity.decodeRelayFrame(data, maxBytes: maxFrameBytes)
            try ProtocolSecurity.validate(frame, expectedMachineId: machineId, expectedDeviceId: deviceId)
            if let error = pairingAckError(frame) { throw error }
            if frame.kind == kind { return frame }
        }
        throw TransportError.timeout
    }

    private func pairingAckError(_ frame: RelayFrame) -> Error? {
        guard frame.kind == "ACK", let code = frame.body["error"]?.stringValue else { return nil }
        let message = frame.body["message"]?.stringValue ?? "Windows rejected the pairing request."
        if code == "UNAUTHORIZED_DEVICE" {
            let lower = message.lowercased()
            if lower.contains("expired") || lower.contains("proof rejected") {
                return TransportError.remote("PAIRING_CODE_INVALID", "Invalid or expired pairing code")
            }
        }
        return TransportError.remote(code, message)
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
