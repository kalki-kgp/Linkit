import CryptoKit
import Foundation

/// JSON envelope that carries an AES-GCM-sealed payload over the wire:
///
///     {"v":1,"enc":"<base64 of nonce||ciphertext||tag>"}
///
/// Encrypt-then-sign: the envelope bytes are what the existing signing layer signs,
/// so tampering is caught at the signature and confidentiality at the AEAD. The
/// 32-byte pairing secret (issued in the QR, stored per peer) keys it via
/// `LinkitSecretBox`. The Kotlin twin (`LinkitWireCrypto.kt`) uses the same shape.
struct EncryptedEnvelope: Codable {
    let v: Int
    let enc: String
}

enum LinkitWireCrypto {
    /// Encrypt a plaintext body for a peer holding `pairingSecret` (standard base64).
    static func seal(pairingSecret: String?, plaintext: Data) throws -> Data {
        let key = try messageKey(pairingSecret)
        let sealed = try LinkitSecretBox.seal(key: key, plaintext: plaintext)
        let envelope = EncryptedEnvelope(v: LinkitSecretBox.version, enc: sealed.base64EncodedString())
        return try JSONEncoder().encode(envelope)
    }

    /// Decrypt a received envelope body using the peer's `pairingSecret`.
    static func open(pairingSecret: String?, body: Data) throws -> Data {
        let key = try messageKey(pairingSecret)
        guard let envelope = try? JSONDecoder().decode(EncryptedEnvelope.self, from: body) else {
            throw HTTPFailure.badRequest("encryption_required", "Request was not encrypted. Update both apps and re-pair.")
        }
        guard envelope.v == LinkitSecretBox.version else {
            throw HTTPFailure.badRequest("encryption_version", "Unsupported encryption version. Update both apps.")
        }
        guard let sealed = Data(base64Encoded: envelope.enc) else {
            throw HTTPFailure.badRequest("invalid_ciphertext", "Encrypted payload is malformed")
        }
        do {
            return try LinkitSecretBox.open(key: key, sealed: sealed)
        } catch {
            throw HTTPFailure.unauthorized("decryption_failed", "Encrypted payload could not be decrypted")
        }
    }

    private static func messageKey(_ pairingSecret: String?) throws -> SymmetricKey {
        guard let pairingSecret,
              let psk = Data(base64Encoded: pairingSecret),
              psk.count == LinkitSecretBox.pairingSecretByteCount else {
            throw HTTPFailure.unauthorized("not_paired_for_encryption", "No encryption key for this device. Re-pair to enable encryption.")
        }
        return LinkitSecretBox.messageKey(pairingSecret: psk)
    }
}
