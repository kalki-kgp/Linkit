import CryptoKit
import Foundation

/// Confidentiality layer for the Linkit wire protocol.
///
/// Authenticity and integrity already come from the P-256 ECDSA signing layer
/// (`SignedRequestVerifier`). `LinkitSecretBox` adds *secrecy*: payloads are
/// AES-256-GCM sealed under a key derived (HKDF-SHA256) from the 32-byte pairing
/// secret the Mac issues in the pairing QR and both devices then store.
///
/// A sealed blob uses CryptoKit's `combined` layout:
///
///     nonce (12 bytes) || ciphertext || tag (16 bytes)
///
/// The Kotlin side (`LinkitSecretBox.kt`) implements the identical format. The
/// `LinkitSecretBoxTests` (Swift) and `LinkitSecretBoxTest` (Kotlin) golden
/// vectors assert byte-for-byte agreement so the two stay in lockstep.
enum LinkitSecretBox {
    /// Wire-format / key-schedule version. Bump on any breaking change.
    static let version = 1
    /// Length of the pairing secret the Mac issues in the QR.
    static let pairingSecretByteCount = 32

    private static let hkdfSalt = Data("linkit/aead/salt/v1".utf8)
    private static let messageInfo = Data("linkit/aead/message/v1".utf8)

    /// Symmetric key for discrete (non-streamed) message bodies.
    static func messageKey(pairingSecret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: pairingSecret),
            salt: hkdfSalt,
            info: messageInfo,
            outputByteCount: 32
        )
    }

    /// Per-transfer key for streaming file bodies. Unique per transfer (HKDF over the
    /// transfer id + file index) so AES-256-CTR can use a fixed zero counter safely.
    static func transferKey(pairingSecret: Data, transferId: String, fileIndex: Int) -> SymmetricKey {
        let info = Data(("linkit/aead/transfer/v1\n" + transferId + "\n" + String(fileIndex)).utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: pairingSecret),
            salt: hkdfSalt,
            info: info,
            outputByteCount: 32
        )
    }

    /// Seal with an explicit 12-byte nonce. Used by streaming framing and the
    /// golden-vector tests; general callers should use the random-nonce overload.
    static func sealWithNonce(key: SymmetricKey, nonce: Data, plaintext: Data, aad: Data = Data()) throws -> Data {
        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: AES.GCM.Nonce(data: nonce),
            authenticating: aad
        )
        guard let combined = sealedBox.combined else { throw LinkitSecretBoxError.sealFailed }
        return combined
    }

    /// Seal a discrete message with a fresh random 96-bit nonce.
    static func seal(key: SymmetricKey, plaintext: Data, aad: Data = Data()) throws -> Data {
        let sealedBox = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        guard let combined = sealedBox.combined else { throw LinkitSecretBoxError.sealFailed }
        return combined
    }

    /// Open a `nonce || ciphertext || tag` blob. Throws if authentication fails
    /// (wrong key, tampered ciphertext, or mismatched AAD).
    static func open(key: SymmetricKey, sealed: Data, aad: Data = Data()) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: sealed)
        return try AES.GCM.open(sealedBox, using: key, authenticating: aad)
    }
}

enum LinkitSecretBoxError: Error {
    case sealFailed
}
