package tech.kalkikgp.linkit

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.util.UUID

private const val KEY_ALIAS = "linkit_android_p256_signing"

data class AndroidIdentity(
    val deviceId: String,
    val deviceName: String,
    val publicKey: String
)

data class TrustedMac(
    val deviceId: String,
    val deviceName: String,
    val publicKey: String,
    val ip: String,
    val port: Int
)

class IdentityStore(private val context: Context) {
    private val preferences: SharedPreferences =
        context.getSharedPreferences("linkit_identity", Context.MODE_PRIVATE)

    fun identity(): AndroidIdentity {
        ensureKey()
        val publicKey = publicKeyX963Base64()
        return AndroidIdentity(
            deviceId = deviceIdFromPublicKey(publicKey),
            deviceName = android.os.Build.MODEL ?: "Android",
            publicKey = publicKey
        )
    }

    fun sign(canonical: String): String {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val privateKey = keyStore.getKey(KEY_ALIAS, null) as java.security.PrivateKey
        val signature = Signature.getInstance("SHA256withECDSA")
        signature.initSign(privateKey)
        signature.update(canonical.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(signature.sign(), Base64.NO_WRAP)
    }

    fun trustedMac(): TrustedMac? {
        val raw = preferences.getString("trusted_mac", null) ?: return null
        val json = JSONObject(raw)
        return TrustedMac(
            deviceId = json.getString("deviceId"),
            deviceName = json.getString("deviceName"),
            publicKey = json.getString("publicKey"),
            ip = json.getString("ip"),
            port = json.getInt("port")
        )
    }

    fun saveTrustedMac(mac: TrustedMac) {
        val json = JSONObject()
            .put("deviceId", mac.deviceId)
            .put("deviceName", mac.deviceName)
            .put("publicKey", mac.publicKey)
            .put("ip", mac.ip)
            .put("port", mac.port)
        preferences.edit().putString("trusted_mac", json.toString()).apply()
    }

    fun forgetTrustedMac() {
        preferences.edit().remove("trusted_mac").apply()
    }

    private fun ensureKey() {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (keyStore.containsAlias(KEY_ALIAS)) return

        val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
        val spec = KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setUserAuthenticationRequired(false)
            .build()
        generator.initialize(spec)
        generator.generateKeyPair()
    }

    private fun publicKeyX963Base64(): String {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val cert = keyStore.getCertificate(KEY_ALIAS)
        val publicKey = cert.publicKey as ECPublicKey
        val w = publicKey.w
        val bytes = ByteArray(65)
        bytes[0] = 0x04
        w.affineX.toPaddedBytes().copyInto(bytes, 1)
        w.affineY.toPaddedBytes().copyInto(bytes, 33)
        return Base64.encodeToString(bytes, Base64.NO_WRAP)
    }

    private fun BigInteger.toPaddedBytes(): ByteArray {
        val raw = toByteArray()
        val positive = if (raw.size > 32) raw.takeLast(32).toByteArray() else raw
        return ByteArray(32 - positive.size) + positive
    }

    companion object {
        fun deviceIdFromPublicKey(publicKeyBase64: String): String {
            val digest = MessageDigest.getInstance("SHA-256")
                .digest(Base64.decode(publicKeyBase64, Base64.DEFAULT))
            return digest.toHex().take(32)
        }

        fun nonce(): String = UUID.randomUUID().toString().replace("-", "")
    }
}
