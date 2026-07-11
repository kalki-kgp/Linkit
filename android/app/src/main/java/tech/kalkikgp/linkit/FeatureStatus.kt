package tech.kalkikgp.linkit

import android.content.Context
import android.os.PowerManager
import org.json.JSONArray
import org.json.JSONObject

/**
 * Health of a single Linkit feature. `state` is the machine-readable status the two apps share
 * over the wire so each device can render the *other* device's self-reported feature health;
 * `detail` is the human-readable reason shown under the title.
 */
enum class FeatureState(val wire: String) {
    /** Enabled and working. */
    ON("on"),

    /** Deliberately off (user toggle). */
    OFF("off"),

    /** The user wants it on, but it is broken — missing permission or an unbound service. */
    ATTENTION("attention"),

    /** Not available on this device / OS. */
    UNSUPPORTED("unsupported");

    companion object {
        fun fromWire(value: String?): FeatureState =
            values().firstOrNull { it.wire == value } ?: OFF
    }
}

data class FeatureStatus(
    val id: String,
    val title: String,
    val state: FeatureState,
    val detail: String
) {
    fun toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("title", title)
        .put("state", state.wire)
        .put("detail", detail)

    companion object {
        fun fromJson(json: JSONObject): FeatureStatus = FeatureStatus(
            id = json.optString("id"),
            title = json.optString("title"),
            state = FeatureState.fromWire(json.optString("state")),
            detail = json.optString("detail")
        )
    }
}

fun List<FeatureStatus>.toJsonArray(): JSONArray {
    val array = JSONArray()
    forEach { array.put(it.toJson()) }
    return array
}

fun featureStatusesFromJson(array: JSONArray?): List<FeatureStatus> {
    if (array == null) return emptyList()
    return (0 until array.length()).mapNotNull { index ->
        array.optJSONObject(index)?.let(FeatureStatus::fromJson)
    }
}

/**
 * Computes this phone's live feature health. Sources are authoritative runtime signals (real
 * listener bind state, granted permissions, whether the foreground service is running) rather
 * than persisted toggles alone — so a feature that silently stopped (e.g. a notification listener
 * the OS dropped after reboot) reports `ATTENTION`, not a misleading `ON`.
 */
object AndroidFeatureStatus {
    const val ID_NOTIFICATION_MIRROR = "notification_mirror"
    const val ID_CLIPBOARD_SYNC = "clipboard_sync"
    const val ID_PHONE_CONTROL = "phone_control"
    const val ID_RECEIVER = "receiver_service"
    const val ID_BATTERY = "battery_exemption"

    fun local(context: Context, settings: LinkitSettings): List<FeatureStatus> = listOf(
        notificationMirror(context, settings),
        clipboardSync(settings),
        phoneControl(context),
        receiverService(context),
        batteryExemption(context)
    )

    private fun notificationMirror(context: Context, settings: LinkitSettings): FeatureStatus {
        val state: FeatureState
        val detail: String
        when {
            !settings.notificationMirrorEnabled -> {
                state = FeatureState.OFF
                detail = "Turn on to mirror phone notifications to your Mac."
            }
            !NotificationAccess.isGranted(context) -> {
                state = FeatureState.ATTENTION
                detail = "Grant notification access so Linkit can read notifications."
            }
            !NotificationMirrorState.listenerConnected -> {
                state = FeatureState.ATTENTION
                detail = "On, but not receiving — tap to reconnect the listener."
            }
            else -> {
                state = FeatureState.ON
                detail = "Mirroring phone notifications to your Mac."
            }
        }
        return FeatureStatus(ID_NOTIFICATION_MIRROR, "Notification mirroring", state, detail)
    }

    private fun clipboardSync(settings: LinkitSettings): FeatureStatus {
        val state = if (settings.clipboardSyncEnabled) FeatureState.ON else FeatureState.OFF
        val detail = if (settings.clipboardSyncEnabled) {
            "Copies text to your Mac. Android → Mac only syncs while Linkit is open (OS limit)."
        } else {
            "Turn on to copy clipboard text to your Mac while Linkit is open."
        }
        return FeatureStatus(ID_CLIPBOARD_SYNC, "Clipboard sync", state, detail)
    }

    private fun phoneControl(context: Context): FeatureStatus {
        val status = PhonePermissions.status(context)
        val state = if (status.canWatchCalls) FeatureState.ON else FeatureState.ATTENTION
        return FeatureStatus(ID_PHONE_CONTROL, "Phone controls", state, status.summary)
    }

    private fun receiverService(context: Context): FeatureStatus {
        val paired = IdentityStore(context).trustedMac() != null
        val state = when {
            !paired -> FeatureState.OFF
            LinkitReceiverService.running -> FeatureState.ON
            else -> FeatureState.ATTENTION
        }
        val detail = when (state) {
            FeatureState.ON -> "Listening for Mac drops in the background."
            FeatureState.ATTENTION -> "Open Linkit to restart the background receiver."
            else -> "Pair with a Mac to receive files."
        }
        return FeatureStatus(ID_RECEIVER, "Background receiver", state, detail)
    }

    private fun batteryExemption(context: Context): FeatureStatus {
        val power = context.getSystemService(PowerManager::class.java)
        val exempt = power?.isIgnoringBatteryOptimizations(context.packageName) == true
        val state = if (exempt) FeatureState.ON else FeatureState.ATTENTION
        val detail = if (exempt) {
            "Linkit can stay connected while the screen is off."
        } else {
            "Allow background activity so the link survives Doze."
        }
        return FeatureStatus(ID_BATTERY, "Stay connected in background", state, detail)
    }
}
