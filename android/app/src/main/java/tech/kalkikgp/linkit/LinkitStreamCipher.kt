package tech.kalkikgp.linkit

import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Size-preserving AES-256-CTR for streaming file bodies — the Kotlin twin of the
 * Swift `LinkitStreamCipher` (CommonCrypto). Confidentiality only; integrity for
 * transfers is the existing end-to-end SHA-256 plus the signed upload slot.
 *
 * One instance per file transfer, keyed by [LinkitSecretBox.transferKey] (unique per
 * transfer, so the zero starting counter is safe). The counter advances across
 * [update] calls. CTR encryption and decryption are the same operation.
 */
class LinkitStreamCipher(key: ByteArray) {
    private val cipher: Cipher = Cipher.getInstance("AES/CTR/NoPadding").apply {
        init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(ByteArray(16)))
    }

    /** Transform a chunk (encrypt == decrypt for CTR), advancing the keystream counter. */
    fun update(data: ByteArray, offset: Int = 0, length: Int = data.size): ByteArray =
        cipher.update(data, offset, length) ?: ByteArray(0)
}
