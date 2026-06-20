import CommonCrypto
import CryptoKit
import Foundation

/// Size-preserving AES-256-CTR for streaming file bodies. CryptoKit has no raw
/// stream cipher, so this wraps CommonCrypto's CTR mode (big-endian counter), which
/// matches Android's `javax` `AES/CTR/NoPadding` byte-for-byte (golden-vector tested).
///
/// This provides **confidentiality only**. Integrity/authenticity for file transfers
/// already come from the signed upload slot plus the end-to-end SHA-256 the receiver
/// verifies at finalize — a tampered stream decrypts to the wrong bytes and is
/// rejected there. Confidentiality without per-chunk auth lets the ciphertext stay
/// exactly the plaintext size, so none of the transfer's size/token/signature
/// accounting changes.
///
/// One instance per file transfer, keyed by `LinkitSecretBox.transferKey` (unique per
/// transfer, so the zero starting counter is safe). The counter advances across
/// `update` calls. CTR encryption and decryption are the same operation.
final class LinkitStreamCipher {
    private var cryptor: CCCryptorRef?

    init(key: SymmetricKey) throws {
        let keyData = key.withUnsafeBytes { Data($0) }
        var iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        var ref: CCCryptorRef?
        let status = keyData.withUnsafeBytes { keyBytes -> CCCryptorStatus in
            CCCryptorCreateWithMode(
                CCOperation(kCCEncrypt),
                CCMode(kCCModeCTR),
                CCAlgorithm(kCCAlgorithmAES),
                CCPadding(ccNoPadding),
                &iv,
                keyBytes.baseAddress,
                keyData.count,
                nil, 0, 0,
                CCModeOptions(kCCModeOptionCTR_BE),
                &ref
            )
        }
        guard status == kCCSuccess, let ref else {
            throw LinkitSecretBoxError.sealFailed
        }
        cryptor = ref
    }

    deinit {
        if let cryptor { CCCryptorRelease(cryptor) }
    }

    /// Transform a chunk (encrypt == decrypt for CTR), advancing the keystream counter.
    func update(_ data: Data) throws -> Data {
        guard let cryptor, !data.isEmpty else { return Data() }
        var output = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = data.withUnsafeBytes { input in
            CCCryptorUpdate(cryptor, input.baseAddress, data.count, &output, output.count, &moved)
        }
        guard status == kCCSuccess else { throw LinkitSecretBoxError.sealFailed }
        return Data(output.prefix(moved))
    }
}
