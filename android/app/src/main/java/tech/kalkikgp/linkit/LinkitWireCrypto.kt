package tech.kalkikgp.linkit

import android.util.Base64
import org.json.JSONObject

/**
 * JSON envelope carrying an AES-GCM-sealed payload — the Kotlin twin of the Swift
 * `LinkitWireCrypto`:
 *
 *     {"v":1,"enc":"<base64 of nonce||ciphertext||tag>"}
 *
 * Encrypt-then-sign: the envelope bytes are what the signing layer signs. The
 * 32-byte pairing secret (from the QR, stored with the trusted Mac) keys it via
 * [LinkitSecretBox].
 */
object LinkitWireCrypto {
    /** Encrypt a plaintext body for the peer holding [pairingSecret] (standard base64). */
    fun seal(pairingSecret: String?, plaintext: ByteArray): String {
        val key = messageKey(pairingSecret)
        val sealed = LinkitSecretBox.seal(key, plaintext)
        return JSONObject()
            .put("v", LinkitSecretBox.VERSION)
            .put("enc", Base64.encodeToString(sealed, Base64.NO_WRAP))
            .toString()
    }

    /** Decrypt a received envelope body using the peer's [pairingSecret]. */
    fun open(pairingSecret: String?, body: ByteArray): ByteArray {
        val key = messageKey(pairingSecret)
        val envelope = try {
            JSONObject(String(body, Charsets.UTF_8))
        } catch (e: Exception) {
            throw DropHttpFailure(400, "encryption_required", "Request was not encrypted. Update both apps and re-pair.")
        }
        if (envelope.optInt("v", -1) != LinkitSecretBox.VERSION) {
            throw DropHttpFailure(400, "encryption_version", "Unsupported encryption version. Update both apps.")
        }
        val enc = envelope.optString("enc").takeIf { it.isNotBlank() }
            ?: throw DropHttpFailure(400, "invalid_ciphertext", "Encrypted payload is malformed")
        val sealed = try {
            Base64.decode(enc, Base64.DEFAULT)
        } catch (e: Exception) {
            throw DropHttpFailure(400, "invalid_ciphertext", "Encrypted payload is malformed")
        }
        return try {
            LinkitSecretBox.open(key, sealed)
        } catch (e: Exception) {
            throw DropHttpFailure(401, "decryption_failed", "Encrypted payload could not be decrypted")
        }
    }

    private fun messageKey(pairingSecret: String?): ByteArray {
        val psk = pairingSecret?.let { runCatching { Base64.decode(it, Base64.DEFAULT) }.getOrNull() }
        if (psk == null || psk.size != LinkitSecretBox.PAIRING_SECRET_BYTE_COUNT) {
            throw DropHttpFailure(401, "not_paired_for_encryption", "No encryption key for this device. Re-pair to enable encryption.")
        }
        return LinkitSecretBox.messageKey(psk)
    }
}
