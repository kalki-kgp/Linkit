package tech.kalkikgp.linkit

import org.json.JSONException
import org.json.JSONObject
import java.net.URLDecoder

data class MacPairingPayload(
    val deviceId: String,
    val deviceName: String,
    val publicKey: String,
    val ip: String,
    val port: Int,
    val pairingToken: String,
    val pairingChallenge: String,
    val pairingSecret: String,
    val pairingTokenExpiresAt: String? = null
)

object PairingPayloadParser {
    private const val MAX_PAYLOAD_BYTES = 16 * 1024

    fun parse(raw: String): MacPairingPayload {
        val trimmed = raw.trim()
        val jsonText = if (trimmed.startsWith("linkit://pair?payload=")) {
            URLDecoder.decode(trimmed.removePrefix("linkit://pair?payload="), Charsets.UTF_8.name())
        } else {
            trimmed
        }
        require(jsonText.toByteArray(Charsets.UTF_8).size <= MAX_PAYLOAD_BYTES) { "Pairing payload is too large" }
        val json = try {
            JSONObject(jsonText)
        } catch (error: JSONException) {
            throw IllegalArgumentException("Malformed pairing payload", error)
        }
        val version = json.optInt("v", 1)
        require(version == 1) { "Unsupported pairing payload version" }
        return MacPairingPayload(
            deviceId = json.requiredString("deviceId"),
            deviceName = json.optString("deviceName", "Linkit Mac"),
            publicKey = json.requiredString("publicKey"),
            ip = json.requiredString("ip"),
            port = json.optInt("port").takeIf { it in 1..65535 }
                ?: throw IllegalArgumentException("Missing or invalid port"),
            pairingToken = json.requiredString("pairingToken"),
            pairingChallenge = json.requiredString("pairingChallenge"),
            pairingSecret = json.requiredString("pairingSecret"),
            pairingTokenExpiresAt = json.optString("pairingTokenExpiresAt").takeIf { it.isNotBlank() }
        )
    }

    private fun JSONObject.requiredString(name: String): String {
        return optString(name).takeIf { it.isNotBlank() }
            ?: throw IllegalArgumentException("Missing required pairing field: $name")
    }
}

object LinkitPairingChallenge {
    fun canonicalString(
        macDeviceId: String,
        androidDeviceId: String,
        androidPublicKey: String,
        pairingToken: String,
        challenge: String
    ): String = listOf(
        "LINKIT_PAIR",
        macDeviceId,
        androidDeviceId,
        androidPublicKey,
        pairingToken,
        challenge
    ).joinToString("\n")
}

object LinkitIdentityProof {
    fun canonicalString(deviceId: String, publicKey: String, challenge: String): String = listOf(
        "LINKIT_IDENTITY_PROOF",
        deviceId,
        publicKey,
        challenge
    ).joinToString("\n")
}
