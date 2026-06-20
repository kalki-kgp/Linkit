import CryptoKit
import XCTest
@testable import LinkitMacCore

/// Golden vectors shared byte-for-byte with the Kotlin `LinkitSecretBoxTest`.
/// If either side changes the key schedule or wire format, one of these fails —
/// which is exactly the cross-platform divergence we want to catch before release.
final class LinkitSecretBoxTests: XCTestCase {
    // Fixed inputs (also used by the Kotlin test).
    private let psk = Data((0..<32).map { UInt8($0) })
    private let nonce = Data((0..<12).map { UInt8($0) })
    private let nonce2 = Data((12..<24).map { UInt8($0) })
    private let plaintext = Data("the quick brown fox".utf8)
    private let aad = Data("linkit-aad".utf8)

    // Expected outputs (CryptoKit reference; independently HKDF-checked in Python).
    private let expectedKeyHex = "a5af56d662f04bebcba0f2688d0561138f5b29f9c53825c53636e058a3563bad"
    private let expectedSealedHex = "000102030405060708090a0b7b1964805f01083ce73b9c46e1ef07a6ed08b2df68d036afb9b479e6503d80123a769e"
    private let expectedSealedNoAadHex = "0c0d0e0f1011121314151617de6284c0b0c793f34b94d1b0d4abae15a69cce39fef4491962b7f1f4aa0636e929dd9a"

    func testMessageKeyMatchesGoldenVector() {
        let key = LinkitSecretBox.messageKey(pairingSecret: psk)
        let keyData = key.withUnsafeBytes { Data($0) }
        XCTAssertEqual(keyData.linkitTestHex, expectedKeyHex)
    }

    func testSealMatchesGoldenVectorWithAAD() throws {
        let key = LinkitSecretBox.messageKey(pairingSecret: psk)
        let sealed = try LinkitSecretBox.sealWithNonce(key: key, nonce: nonce, plaintext: plaintext, aad: aad)
        XCTAssertEqual(sealed.linkitTestHex, expectedSealedHex)
    }

    func testSealMatchesGoldenVectorNoAAD() throws {
        let key = LinkitSecretBox.messageKey(pairingSecret: psk)
        let sealed = try LinkitSecretBox.sealWithNonce(key: key, nonce: nonce2, plaintext: plaintext)
        XCTAssertEqual(sealed.linkitTestHex, expectedSealedNoAadHex)
    }

    func testRandomNonceRoundTrip() throws {
        let key = LinkitSecretBox.messageKey(pairingSecret: psk)
        let sealed = try LinkitSecretBox.seal(key: key, plaintext: plaintext, aad: aad)
        XCTAssertNotEqual(sealed, try LinkitSecretBox.seal(key: key, plaintext: plaintext, aad: aad),
                          "random nonce should make repeated seals differ")
        let opened = try LinkitSecretBox.open(key: key, sealed: sealed, aad: aad)
        XCTAssertEqual(opened, plaintext)
    }

    func testOpenRejectsTamperedCiphertext() throws {
        let key = LinkitSecretBox.messageKey(pairingSecret: psk)
        var sealed = try LinkitSecretBox.sealWithNonce(key: key, nonce: nonce, plaintext: plaintext, aad: aad)
        sealed[sealed.count - 1] ^= 0x01 // flip a tag bit
        XCTAssertThrowsError(try LinkitSecretBox.open(key: key, sealed: sealed, aad: aad))
    }

    func testOpenRejectsWrongAAD() throws {
        let key = LinkitSecretBox.messageKey(pairingSecret: psk)
        let sealed = try LinkitSecretBox.sealWithNonce(key: key, nonce: nonce, plaintext: plaintext, aad: aad)
        XCTAssertThrowsError(try LinkitSecretBox.open(key: key, sealed: sealed, aad: Data("other".utf8)))
    }

    // MARK: - Streaming (AES-256-CTR) — shared with the Kotlin LinkitSecretBoxTest

    func testTransferKeyMatchesGoldenVector() {
        let key = LinkitSecretBox.transferKey(pairingSecret: psk, transferId: "tx-123", fileIndex: 0)
        XCTAssertEqual(key.withUnsafeBytes { Data($0) }.linkitTestHex,
                       "ebfc1284ec44357cebaf58f9e795095a5bd786e0538575eb76c21dbc64aa4942")
    }

    func testStreamCipherMatchesGoldenVector() throws {
        let key = LinkitSecretBox.transferKey(pairingSecret: psk, transferId: "tx-123", fileIndex: 0)
        let ciphertext = try LinkitStreamCipher(key: key)
            .update(Data("streaming ciphertext test vector payload spanning blocks!!".utf8))
        XCTAssertEqual(ciphertext.linkitTestHex,
                       "3ac6db724c45457bf039d4ae40a125b3d192bf8ea910f15bbd7f88b3b4316a5035376816b3b51d3ecabbab8ef4c69f86c35e786749b977c58a4c")
    }

    func testStreamCipherChunkedMatchesSingleAndRoundTrips() throws {
        let key = LinkitSecretBox.transferKey(pairingSecret: psk, transferId: "tx-9", fileIndex: 2)
        let plaintext = Data((0..<5000).map { UInt8($0 & 0xff) })
        // Counter must persist across update() calls: chunked == single-shot.
        let enc = try LinkitStreamCipher(key: key)
        var chunked = try enc.update(plaintext.prefix(1000))
        chunked += try enc.update(Data(plaintext.suffix(from: 1000)))
        let single = try LinkitStreamCipher(key: key).update(plaintext)
        XCTAssertEqual(chunked, single)
        // CTR decrypt is the same op with a fresh cipher.
        XCTAssertEqual(try LinkitStreamCipher(key: key).update(chunked), plaintext)
    }
}

private extension Data {
    var linkitTestHex: String { map { String(format: "%02x", $0) }.joined() }
}
