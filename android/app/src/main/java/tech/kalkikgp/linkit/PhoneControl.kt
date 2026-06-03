package tech.kalkikgp.linkit

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.telecom.TelecomManager
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import org.json.JSONObject

data class PhoneControlPermissionStatus(
    val canWatchCalls: Boolean,
    val canPlaceDirectCalls: Boolean,
    val canControlCalls: Boolean
) {
    val summary: String
        get() = when {
            canWatchCalls && canPlaceDirectCalls && canControlCalls -> "Phone controls enabled"
            canWatchCalls -> "Incoming call mirror enabled; call actions need permission"
            else -> "Phone controls need permission"
        }
}

object PhonePermissions {
    val requested = arrayOf(
        Manifest.permission.READ_PHONE_STATE,
        Manifest.permission.CALL_PHONE,
        Manifest.permission.ANSWER_PHONE_CALLS
    )

    fun status(context: Context): PhoneControlPermissionStatus {
        fun granted(permission: String): Boolean =
            ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

        return PhoneControlPermissionStatus(
            canWatchCalls = granted(Manifest.permission.READ_PHONE_STATE),
            canPlaceDirectCalls = granted(Manifest.permission.CALL_PHONE),
            canControlCalls = granted(Manifest.permission.ANSWER_PHONE_CALLS)
        )
    }
}

object PhoneNumberPolicy {
    private val allowedDisplay = Regex("""^\+?[0-9 .()\-]{2,32}$""")

    fun normalizedDialNumber(input: String): String? {
        val trimmed = input.trim()
        if (!allowedDisplay.matches(trimmed)) return null
        val normalized = buildString {
            trimmed.forEachIndexed { index, char ->
                when {
                    char.isDigit() -> append(char)
                    char == '+' && index == 0 -> append(char)
                    char == ' ' || char == '.' || char == '(' || char == ')' || char == '-' -> Unit
                    else -> return null
                }
            }
        }
        val digitCount = normalized.count(Char::isDigit)
        return normalized.takeIf { digitCount in 2..15 }
    }
}

class AndroidPhoneController(private val context: Context) {
    fun handleAction(type: String, text: String): JSONObject {
        return when (type) {
            "phone_call" -> startCall(text)
            "phone_answer" -> answerCall()
            "phone_decline", "phone_hangup" -> endCall(type)
            else -> throw DropHttpFailure(400, "unsupported_phone_action", "Phone action is not supported")
        }
    }

    private fun startCall(rawNumber: String): JSONObject {
        val number = PhoneNumberPolicy.normalizedDialNumber(rawNumber)
            ?: throw DropHttpFailure(400, "invalid_phone_number", "Phone number is invalid")
        val permissionStatus = PhonePermissions.status(context)
        val action = if (permissionStatus.canPlaceDirectCalls) Intent.ACTION_CALL else Intent.ACTION_DIAL
        val intent = Intent(action, Uri.fromParts("tel", number, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        return JSONObject()
            .put("status", "ok")
            .put("type", "phone_call")
            .put("mode", if (action == Intent.ACTION_CALL) "direct_call" else "opened_dialer")
    }

    private fun answerCall(): JSONObject {
        if (!PhonePermissions.status(context).canControlCalls) {
            throw DropHttpFailure(403, "missing_phone_control_permission", "Grant phone control permission on Android first")
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            throw DropHttpFailure(501, "phone_control_unsupported", "Answering calls requires Android 8 or newer")
        }
        val telecom = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        @Suppress("DEPRECATION")
        telecom.acceptRingingCall()
        return JSONObject().put("status", "ok").put("type", "phone_answer")
    }

    private fun endCall(type: String): JSONObject {
        if (!PhonePermissions.status(context).canControlCalls) {
            throw DropHttpFailure(403, "missing_phone_control_permission", "Grant phone control permission on Android first")
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            throw DropHttpFailure(501, "phone_control_unsupported", "Ending calls requires Android 9 or newer")
        }
        val telecom = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        @Suppress("DEPRECATION")
        val ended = telecom.endCall()
        return JSONObject()
            .put("status", if (ended) "ok" else "no_call")
            .put("type", type)
    }
}

class PhoneCallBridge(
    private val context: Context,
    private val identityStore: IdentityStore,
    private val client: LinkitClient,
    private val scope: CoroutineScope
) {
    private val telephonyManager = context.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
    private var callback: TelephonyCallback? = null
    private var legacyListener: PhoneStateListener? = null
    private var lastPayload: String? = null

    fun start() {
        if (!PhonePermissions.status(context).canWatchCalls) {
            DebugTelemetry.recordEvent("phone", "call bridge disabled; READ_PHONE_STATE missing")
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val next = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                override fun onCallStateChanged(state: Int) {
                    publishState(state, null)
                }
            }
            telephonyManager.registerTelephonyCallback(context.mainExecutor, next)
            callback = next
        } else {
            @Suppress("DEPRECATION")
            val next = object : PhoneStateListener() {
                @Deprecated("Deprecated by platform")
                override fun onCallStateChanged(state: Int, phoneNumber: String?) {
                    publishState(state, phoneNumber?.takeIf { it.isNotBlank() })
                }
            }
            @Suppress("DEPRECATION")
            telephonyManager.listen(next, PhoneStateListener.LISTEN_CALL_STATE)
            legacyListener = next
        }
        DebugTelemetry.recordEvent("phone", "call bridge started")
    }

    fun stop() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            callback?.let { telephonyManager.unregisterTelephonyCallback(it) }
        }
        @Suppress("DEPRECATION")
        legacyListener?.let { telephonyManager.listen(it, PhoneStateListener.LISTEN_NONE) }
        callback = null
        legacyListener = null
    }

    private fun publishState(callState: Int, number: String?) {
        val state = when (callState) {
            TelephonyManager.CALL_STATE_RINGING -> "ringing"
            TelephonyManager.CALL_STATE_OFFHOOK -> "active"
            else -> "idle"
        }
        val permissions = PhonePermissions.status(context)
        val payload = JSONObject()
            .put("state", state)
            .put("number", number ?: JSONObject.NULL)
            .put("timestampMillis", System.currentTimeMillis())
            .put("canAnswer", permissions.canControlCalls)
            .put("canEnd", permissions.canControlCalls && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
            .toString()
        if (payload == lastPayload) return
        lastPayload = payload
        scope.launch {
            val mac = identityStore.trustedMac() ?: return@launch
            runCatching {
                client.sendAction(mac, identityStore, "phone_state", payload)
            }.onSuccess {
                DebugTelemetry.recordEvent("phone", "sent call state $state")
            }.onFailure { error ->
                DebugTelemetry.recordEvent("phone", "call state send failed: ${error.message}")
            }
        }
    }
}
