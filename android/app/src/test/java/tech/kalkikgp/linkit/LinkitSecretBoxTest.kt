package tech.kalkikgp.linkit

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import javax.crypto.AEADBadTagException

/**
 * Golden vectors shared byte-for-byte with the Swift `LinkitSecretBoxTests`.
 * The expected outputs were produced by Apple's CryptoKit (the Swift side) and
 * the HKDF value was independently cross-checked in Python. If the Kotlin AES-GCM
 * / HKDF implementation ever drifts from the Swift one, these fail.
 */
class LinkitSecretBoxTest {
    private val psk = ByteArray(32) { it.toByte() }
    private val nonce = ByteArray(12) { it.toByte() }
    private val nonce2 = ByteArray(12) { (it + 12).toByte() }
    private val plaintext = "the quick brown fox".toByteArray(Charsets.UTF_8)
    private val aad = "linkit-aad".toByteArray(Charsets.UTF_8)

    private val expectedKeyHex = "a5af56d662f04bebcba0f2688d0561138f5b29f9c53825c53636e058a3563bad"
    private val expectedSealedHex = "000102030405060708090a0b7b1964805f01083ce73b9c46e1ef07a6ed08b2df68d036afb9b479e6503d80123a769e"
    private val expectedSealedNoAadHex = "0c0d0e0f1011121314151617de6284c0b0c793f34b94d1b0d4abae15a69cce39fef4491962b7f1f4aa0636e929dd9a"

    @Test
    fun messageKeyMatchesGoldenVector() {
        assertEquals(expectedKeyHex, LinkitSecretBox.messageKey(psk).toHex())
    }

    @Test
    fun sealMatchesGoldenVectorWithAad() {
        val key = LinkitSecretBox.messageKey(psk)
        assertEquals(expectedSealedHex, LinkitSecretBox.sealWithNonce(key, nonce, plaintext, aad).toHex())
    }

    @Test
    fun sealMatchesGoldenVectorNoAad() {
        val key = LinkitSecretBox.messageKey(psk)
        assertEquals(expectedSealedNoAadHex, LinkitSecretBox.sealWithNonce(key, nonce2, plaintext).toHex())
    }

    @Test
    fun randomNonceRoundTrip() {
        val key = LinkitSecretBox.messageKey(psk)
        val a = LinkitSecretBox.seal(key, plaintext, aad)
        val b = LinkitSecretBox.seal(key, plaintext, aad)
        assertFalse("random nonce should make repeated seals differ", a.contentEquals(b))
        assertArrayEquals(plaintext, LinkitSecretBox.open(key, a, aad))
    }

    @Test(expected = AEADBadTagException::class)
    fun openRejectsTamper() {
        val key = LinkitSecretBox.messageKey(psk)
        val sealed = LinkitSecretBox.sealWithNonce(key, nonce, plaintext, aad)
        sealed[sealed.size - 1] = (sealed[sealed.size - 1].toInt() xor 1).toByte()
        LinkitSecretBox.open(key, sealed, aad)
    }

    @Test(expected = AEADBadTagException::class)
    fun openRejectsWrongAad() {
        val key = LinkitSecretBox.messageKey(psk)
        val sealed = LinkitSecretBox.sealWithNonce(key, nonce, plaintext, aad)
        LinkitSecretBox.open(key, sealed, "other".toByteArray(Charsets.UTF_8))
    }

    // Streaming (AES-256-CTR) — shared vectors with the Swift LinkitSecretBoxTests.

    @Test
    fun transferKeyMatchesGoldenVector() {
        assertEquals(
            "ebfc1284ec44357cebaf58f9e795095a5bd786e0538575eb76c21dbc64aa4942",
            LinkitSecretBox.transferKey(psk, "tx-123", 0).toHex()
        )
    }

    @Test
    fun streamCipherMatchesGoldenVector() {
        val key = LinkitSecretBox.transferKey(psk, "tx-123", 0)
        val ct = LinkitStreamCipher(key)
            .update("streaming ciphertext test vector payload spanning blocks!!".toByteArray(Charsets.UTF_8))
        assertEquals(
            "3ac6db724c45457bf039d4ae40a125b3d192bf8ea910f15bbd7f88b3b4316a5035376816b3b51d3ecabbab8ef4c69f86c35e786749b977c58a4c",
            ct.toHex()
        )
    }

    @Test
    fun streamCipherChunkedMatchesSingleAndRoundTrips() {
        val key = LinkitSecretBox.transferKey(psk, "tx-9", 2)
        val plaintext = ByteArray(5000) { (it and 0xff).toByte() }
        val enc = LinkitStreamCipher(key)
        val chunked = enc.update(plaintext, 0, 1000) + enc.update(plaintext, 1000, 4000)
        assertArrayEquals(LinkitStreamCipher(key).update(plaintext), chunked)
        assertArrayEquals(plaintext, LinkitStreamCipher(key).update(chunked))
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }
}
