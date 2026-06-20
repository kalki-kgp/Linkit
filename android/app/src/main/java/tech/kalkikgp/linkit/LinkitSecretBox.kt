package tech.kalkikgp.linkit

import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Confidentiality layer for the Linkit wire protocol — the Kotlin twin of the
 * Swift `LinkitSecretBox`.
 *
 * Authenticity/integrity already come from the P-256 ECDSA signing layer; this
 * adds secrecy: payloads are AES-256-GCM sealed under a key derived (HKDF-SHA256)
 * from the 32-byte pairing secret the Mac issues in the pairing QR.
 *
 * Sealed blob layout (matches CryptoKit's `combined` form):
 *
 *     nonce (12 bytes) || ciphertext || tag (16 bytes)
 *
 * The `LinkitSecretBoxTest` (Kotlin) and `LinkitSecretBoxTests` (Swift) golden
 * vectors assert byte-for-byte agreement so the two implementations stay locked.
 */
object LinkitSecretBox {
    /** Wire-format / key-schedule version. Bump on any breaking change. */
    const val VERSION = 1

    /** Length of the pairing secret the Mac issues in the QR. */
    const val PAIRING_SECRET_BYTE_COUNT = 32

    private const val NONCE_LEN = 12
    private const val TAG_BITS = 128
    private val HKDF_SALT = "linkit/aead/salt/v1".toByteArray(Charsets.UTF_8)
    private val MESSAGE_INFO = "linkit/aead/message/v1".toByteArray(Charsets.UTF_8)
    private val EMPTY = ByteArray(0)
    private val random = SecureRandom()

    /** Symmetric key for discrete (non-streamed) message bodies. */
    fun messageKey(pairingSecret: ByteArray): ByteArray =
        hkdfSha256(pairingSecret, HKDF_SALT, MESSAGE_INFO, 32)

    /** Per-transfer key for streaming file bodies (unique per transfer → CTR zero counter is safe). */
    fun transferKey(pairingSecret: ByteArray, transferId: String, fileIndex: Int): ByteArray =
        hkdfSha256(
            pairingSecret,
            HKDF_SALT,
            "linkit/aead/transfer/v1\n$transferId\n$fileIndex".toByteArray(Charsets.UTF_8),
            32
        )

    /** Seal with an explicit 12-byte nonce (streaming framing + golden vectors). */
    fun sealWithNonce(key: ByteArray, nonce: ByteArray, plaintext: ByteArray, aad: ByteArray = EMPTY): ByteArray {
        require(nonce.size == NONCE_LEN) { "nonce must be $NONCE_LEN bytes" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
        if (aad.isNotEmpty()) cipher.updateAAD(aad)
        return nonce + cipher.doFinal(plaintext)
    }

    /** Seal a discrete message with a fresh random 96-bit nonce. */
    fun seal(key: ByteArray, plaintext: ByteArray, aad: ByteArray = EMPTY): ByteArray {
        val nonce = ByteArray(NONCE_LEN).also { random.nextBytes(it) }
        return sealWithNonce(key, nonce, plaintext, aad)
    }

    /** Open a `nonce || ciphertext || tag` blob. Throws if authentication fails. */
    fun open(key: ByteArray, sealed: ByteArray, aad: ByteArray = EMPTY): ByteArray {
        require(sealed.size >= NONCE_LEN + TAG_BITS / 8) { "sealed payload too short" }
        val nonce = sealed.copyOfRange(0, NONCE_LEN)
        val body = sealed.copyOfRange(NONCE_LEN, sealed.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
        if (aad.isNotEmpty()) cipher.updateAAD(aad)
        return cipher.doFinal(body)
    }

    /** RFC 5869 HKDF-SHA256 (matches CryptoKit's `HKDF<SHA256>`). */
    private fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(if (salt.isEmpty()) ByteArray(32) else salt, "HmacSHA256"))
        val prk = mac.doFinal(ikm)
        val out = ByteArray(length)
        var t = EMPTY
        var pos = 0
        var counter = 1
        while (pos < length) {
            mac.init(SecretKeySpec(prk, "HmacSHA256"))
            mac.update(t)
            mac.update(info)
            mac.update(byteArrayOf(counter.toByte()))
            t = mac.doFinal()
            val n = minOf(t.size, length - pos)
            t.copyInto(out, pos, 0, n)
            pos += n
            counter++
        }
        return out
    }
}
