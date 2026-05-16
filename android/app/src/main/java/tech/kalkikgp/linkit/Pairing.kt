package tech.kalkikgp.linkit

import org.json.JSONObject
import java.net.URLDecoder

data class MacPairingPayload(
    val deviceId: String,
    val deviceName: String,
    val publicKey: String,
    val ip: String,
    val port: Int,
    val pairingToken: String,
    val pairingTokenExpiresAt: String? = null
)

object PairingPayloadParser {
    fun parse(raw: String): MacPairingPayload {
        val trimmed = raw.trim()
        val jsonText = if (trimmed.startsWith("linkit://pair?payload=")) {
            URLDecoder.decode(trimmed.removePrefix("linkit://pair?payload="), Charsets.UTF_8.name())
        } else {
            trimmed
        }
        val json = JSONObject(jsonText)
        val version = json.optInt("v", 1)
        require(version == 1) { "Unsupported pairing payload version" }
        return MacPairingPayload(
            deviceId = json.getString("deviceId"),
            deviceName = json.optString("deviceName", "Linkit Mac"),
            publicKey = json.getString("publicKey"),
            ip = json.getString("ip"),
            port = json.getInt("port"),
            pairingToken = json.getString("pairingToken"),
            pairingTokenExpiresAt = json.optString("pairingTokenExpiresAt").takeIf { it.isNotBlank() }
        )
    }
}
