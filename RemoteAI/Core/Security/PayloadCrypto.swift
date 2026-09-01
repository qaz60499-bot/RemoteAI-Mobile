import CryptoKit
import Foundation

public struct EncryptedPayload: Codable, Equatable, Sendable {
    public let algorithm: String
    public let nonce: String
    public let ciphertext: String
    public let tag: String

    public init(algorithm: String, nonce: String, ciphertext: String, tag: String) {
        self.algorithm = algorithm
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }
}

public protocol PayloadEncrypting {
    func encrypt(_ payload: Data, using key: SymmetricKey) throws -> EncryptedPayload
    func decrypt(_ payload: EncryptedPayload, using key: SymmetricKey) throws -> Data
}

public struct PayloadCrypto: PayloadEncrypting {
    public init() {}

    public func encrypt(_ payload: Data, using key: SymmetricKey) throws -> EncryptedPayload {
        let sealed = try ChaChaPoly.seal(payload, using: key)
        return EncryptedPayload(
            algorithm: "ChaChaPoly",
            nonce: Data(sealed.nonce).base64EncodedString(),
            ciphertext: sealed.ciphertext.base64EncodedString(),
            tag: sealed.tag.base64EncodedString()
        )
    }

    public func decrypt(_ payload: EncryptedPayload, using key: SymmetricKey) throws -> Data {
        guard payload.algorithm == "ChaChaPoly",
              let nonceData = Data(base64Encoded: payload.nonce),
              let ciphertext = Data(base64Encoded: payload.ciphertext),
              let tag = Data(base64Encoded: payload.tag) else {
            throw TransportError.invalidPayload
        }

        let nonce = try ChaChaPoly.Nonce(data: nonceData)
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try ChaChaPoly.open(box, using: key)
    }

    public static func key(fromPairingSecret secret: Data) -> SymmetricKey {
        let digest = SHA256.hash(data: secret)
        return SymmetricKey(data: Data(digest))
    }
}
