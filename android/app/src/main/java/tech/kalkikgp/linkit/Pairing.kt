package tech.kalkikgp.linkit

import org.json.JSONObject

data class MacPairingPayload(
    val deviceId: String,
    val deviceName: String,
    val publicKey: String,
    val ip: String,
    val port: Int,
    val pairingToken: String
)

object PairingPayloadParser {
    fun parse(raw: String): MacPairingPayload {
        val jsonText = raw.trim().removePrefix("linkit://pair?payload=")
        val json = JSONObject(jsonText)
        val version = json.optInt("v", 1)
        require(version == 1) { "Unsupported pairing payload version" }
        return MacPairingPayload(
            deviceId = json.getString("deviceId"),
            deviceName = json.optString("deviceName", "Linkit Mac"),
            publicKey = json.getString("publicKey"),
            ip = json.getString("ip"),
            port = json.getInt("port"),
            pairingToken = json.getString("pairingToken")
        )
    }
}
