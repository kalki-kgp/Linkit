package tech.kalkikgp.linkit

import org.json.JSONObject

/**
 * The Mac's live condition, mirrored down from the `POST /v1/devices/self` response.
 *
 * The Swift side is `MacSystemStatus` in `LinkitMacCore` — keep the two in lockstep. Every
 * field is nullable because no single Mac has all of them (a Mac mini has no battery, an
 * Ethernet-only Mac has no Wi-Fi signal) and an older Mac sends none of them at all. The UI
 * renders "—" for anything absent rather than inventing a value.
 */
data class MacSystemStatus(
    val batteryPercent: Int? = null,
    val isCharging: Boolean? = null,
    /** `"ac"` or `"battery"`. */
    val powerSource: String? = null,
    val minutesToFull: Int? = null,
    val minutesToEmpty: Int? = null,
    val lowPowerMode: Boolean = false,
    /** `"wifi"`, `"ethernet"`, or `"other"`. */
    val networkKind: String? = null,
    val wifiRssi: Int? = null,
    /** `"excellent" | "good" | "fair" | "weak"`. */
    val wifiQuality: String? = null,
    val freeDiskBytes: Long? = null,
    val totalDiskBytes: Long? = null,
    /** Linkit's own Do Not Disturb window on the Mac, which mutes mirrored phone notifications. */
    val doNotDisturb: Boolean = false,
    val osVersion: String? = null
) {
    val isOnAcPower: Boolean get() = powerSource == "ac"

    companion object {
        fun fromJson(json: JSONObject): MacSystemStatus = MacSystemStatus(
            batteryPercent = json.nullableInt("batteryPercent")?.coerceIn(0, 100),
            isCharging = if (json.has("isCharging") && !json.isNull("isCharging")) {
                json.optBoolean("isCharging")
            } else null,
            powerSource = json.nullableString("powerSource"),
            minutesToFull = json.nullableInt("minutesToFull"),
            minutesToEmpty = json.nullableInt("minutesToEmpty"),
            lowPowerMode = json.optBoolean("lowPowerMode", false),
            networkKind = json.nullableString("networkKind"),
            wifiRssi = json.nullableInt("wifiRssi"),
            wifiQuality = json.nullableString("wifiQuality"),
            freeDiskBytes = json.nullableLong("freeDiskBytes"),
            totalDiskBytes = json.nullableLong("totalDiskBytes"),
            doNotDisturb = json.optBoolean("doNotDisturb", false),
            osVersion = json.nullableString("osVersion")
        )

        private fun JSONObject.nullableString(name: String): String? {
            if (!has(name) || isNull(name)) return null
            return optString(name).takeIf { it.isNotBlank() }
        }

        private fun JSONObject.nullableInt(name: String): Int? {
            if (!has(name) || isNull(name)) return null
            return optInt(name, Int.MIN_VALUE).takeIf { it != Int.MIN_VALUE }
        }

        private fun JSONObject.nullableLong(name: String): Long? {
            if (!has(name) || isNull(name)) return null
            return optLong(name, Long.MIN_VALUE).takeIf { it != Long.MIN_VALUE }
        }
    }
}
