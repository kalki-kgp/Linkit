package tech.kalkikgp.linkit

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.CallLog
import android.provider.ContactsContract
import android.telecom.TelecomManager
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

data class PhoneControlPermissionStatus(
    val canWatchCalls: Boolean,
    val canPlaceDirectCalls: Boolean,
    val canControlCalls: Boolean,
    val canSeeNumbers: Boolean,
    val canResolveContacts: Boolean
) {
    val summary: String
        get() = when {
            canWatchCalls && canPlaceDirectCalls && canControlCalls && canSeeNumbers && canResolveContacts ->
                "Phone controls and caller ID enabled"
            canWatchCalls && canPlaceDirectCalls && canControlCalls ->
                "Phone controls enabled; grant call log and contacts for caller name"
            canWatchCalls && canSeeNumbers && canResolveContacts ->
                "Incoming call mirror with caller ID"
            canWatchCalls && canSeeNumbers ->
                "Incoming call mirror with numbers; grant contacts for names"
            canWatchCalls ->
                "Incoming call mirror enabled; grant call log for caller number"
            else -> "Phone controls need permission"
        }
}

object PhonePermissions {
    val requested = arrayOf(
        Manifest.permission.READ_PHONE_STATE,
        Manifest.permission.READ_CALL_LOG,
        Manifest.permission.READ_CONTACTS,
        Manifest.permission.CALL_PHONE,
        Manifest.permission.ANSWER_PHONE_CALLS
    )

    fun status(context: Context): PhoneControlPermissionStatus {
        fun granted(permission: String): Boolean =
            ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

        return PhoneControlPermissionStatus(
            canWatchCalls = granted(Manifest.permission.READ_PHONE_STATE),
            canPlaceDirectCalls = granted(Manifest.permission.CALL_PHONE),
            canControlCalls = granted(Manifest.permission.ANSWER_PHONE_CALLS),
            canSeeNumbers = granted(Manifest.permission.READ_CALL_LOG),
            canResolveContacts = granted(Manifest.permission.READ_CONTACTS)
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

object PhoneContactLookup {
    fun displayNameForNumber(context: Context, number: String): String? {
        if (!PhonePermissions.status(context).canResolveContacts) return null
        val uri = Uri.withAppendedPath(
            ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
            Uri.encode(number)
        )
        return runCatching {
            context.contentResolver.query(
                uri,
                arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    cursor.getString(0)?.takeIf { it.isNotBlank() }
                } else {
                    null
                }
            }
        }.getOrNull()
    }
}

data class ContactNumberEntry(val name: String, val numbers: List<String>)

data class RecentCallEntry(val number: String, val name: String?, val timestampMillis: Long)

/**
 * Enumerates the on-device address book and recently dialed numbers so the Mac can show a
 * searchable call picker. Read-only; reuses the existing READ_CONTACTS / READ_CALL_LOG grants
 * (the same ones that already power incoming caller ID). Returns empty lists without the grant.
 */
object PhoneDirectory {
    private const val RECENT_LIMIT = 20

    private fun dedupKey(number: String): String = number.filter { it.isDigit() || it == '+' }

    fun contacts(context: Context): List<ContactNumberEntry> {
        if (!PhonePermissions.status(context).canResolveContacts) return emptyList()
        val byContact = LinkedHashMap<Long, Pair<String, MutableList<String>>>()
        runCatching {
            context.contentResolver.query(
                ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                arrayOf(
                    ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
                    ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                    ContactsContract.CommonDataKinds.Phone.NUMBER
                ),
                null,
                null,
                "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} COLLATE NOCASE ASC"
            )?.use { cursor ->
                val idCol = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Phone.CONTACT_ID)
                val nameCol = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
                val numberCol = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Phone.NUMBER)
                while (cursor.moveToNext()) {
                    val id = cursor.getLong(idCol)
                    val name = cursor.getString(nameCol)?.takeIf { it.isNotBlank() } ?: continue
                    val number = cursor.getString(numberCol)?.trim()?.takeIf { it.isNotBlank() } ?: continue
                    val entry = byContact.getOrPut(id) { name to mutableListOf() }
                    val key = dedupKey(number)
                    if (key.isNotEmpty() && entry.second.none { dedupKey(it) == key }) {
                        entry.second.add(number)
                    }
                }
            }
        }
        return byContact.values.mapNotNull { (name, numbers) ->
            numbers.takeIf { it.isNotEmpty() }?.let { ContactNumberEntry(name, it) }
        }
    }

    fun recentDialed(context: Context, limit: Int = RECENT_LIMIT): List<RecentCallEntry> {
        if (!PhonePermissions.status(context).canSeeNumbers) return emptyList()
        val out = mutableListOf<RecentCallEntry>()
        val seen = HashSet<String>()
        runCatching {
            context.contentResolver.query(
                CallLog.Calls.CONTENT_URI,
                arrayOf(CallLog.Calls.NUMBER, CallLog.Calls.CACHED_NAME, CallLog.Calls.DATE),
                "${CallLog.Calls.TYPE} = ?",
                arrayOf(CallLog.Calls.OUTGOING_TYPE.toString()),
                "${CallLog.Calls.DATE} DESC"
            )?.use { cursor ->
                val numberCol = cursor.getColumnIndexOrThrow(CallLog.Calls.NUMBER)
                val nameCol = cursor.getColumnIndexOrThrow(CallLog.Calls.CACHED_NAME)
                val dateCol = cursor.getColumnIndexOrThrow(CallLog.Calls.DATE)
                while (cursor.moveToNext() && out.size < limit) {
                    val number = cursor.getString(numberCol)?.trim()?.takeIf { it.isNotBlank() } ?: continue
                    val key = dedupKey(number)
                    if (key.isEmpty() || !seen.add(key)) continue
                    out.add(
                        RecentCallEntry(
                            number = number,
                            name = cursor.getString(nameCol)?.takeIf { it.isNotBlank() },
                            timestampMillis = cursor.getLong(dateCol)
                        )
                    )
                }
            }
        }
        return out
    }

    fun phonebookJson(context: Context): JSONObject {
        val status = PhonePermissions.status(context)
        val contactsArray = JSONArray()
        for (contact in contacts(context)) {
            contactsArray.put(
                JSONObject()
                    .put("name", contact.name)
                    .put("numbers", JSONArray(contact.numbers))
            )
        }
        val recentArray = JSONArray()
        for (call in recentDialed(context)) {
            recentArray.put(
                JSONObject()
                    .put("number", call.number)
                    .put("name", call.name ?: JSONObject.NULL)
                    .put("timestampMillis", call.timestampMillis)
            )
        }
        return JSONObject()
            .put("contacts", contactsArray)
            .put("recentCalls", recentArray)
            .put(
                "permissions",
                JSONObject()
                    .put("contacts", status.canResolveContacts)
                    .put("callLog", status.canSeeNumbers)
            )
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
    private var phoneStateReceiver: BroadcastReceiver? = null
    private var lastPayload: String? = null
    private var currentCallState: Int = TelephonyManager.CALL_STATE_IDLE
    private var lastIncomingNumber: String? = null
    private val contactNameCache = mutableMapOf<String, String?>()

    private val incomingNumberReceiver = object : BroadcastReceiver() {
        override fun onReceive(receiverContext: Context?, intent: Intent?) {
            if (intent?.action != TelephonyManager.ACTION_PHONE_STATE_CHANGED) return
            val incoming = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)
                ?.takeIf { it.isNotBlank() }
                ?: return
            lastIncomingNumber = incoming
            publishState(currentCallState, lastIncomingNumber)
        }
    }

    fun start() {
        if (!PhonePermissions.status(context).canWatchCalls) {
            DebugTelemetry.recordEvent("phone", "call bridge disabled; READ_PHONE_STATE missing")
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val next = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                override fun onCallStateChanged(state: Int) {
                    publishState(state, lastIncomingNumber)
                }
            }
            telephonyManager.registerTelephonyCallback(context.mainExecutor, next)
            callback = next
        } else {
            @Suppress("DEPRECATION")
            val next = object : PhoneStateListener() {
                @Deprecated("Deprecated by platform")
                override fun onCallStateChanged(state: Int, phoneNumber: String?) {
                    phoneNumber?.takeIf { it.isNotBlank() }?.let { lastIncomingNumber = it }
                    publishState(state, phoneNumber?.takeIf { it.isNotBlank() } ?: lastIncomingNumber)
                }
            }
            @Suppress("DEPRECATION")
            telephonyManager.listen(next, PhoneStateListener.LISTEN_CALL_STATE)
            legacyListener = next
        }
        if (PhonePermissions.status(context).canSeeNumbers) {
            val filter = IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(incomingNumberReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                context.registerReceiver(incomingNumberReceiver, filter)
            }
            phoneStateReceiver = incomingNumberReceiver
        }
        DebugTelemetry.recordEvent("phone", "call bridge started")
    }

    fun stop() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            callback?.let { telephonyManager.unregisterTelephonyCallback(it) }
        }
        @Suppress("DEPRECATION")
        legacyListener?.let { telephonyManager.listen(it, PhoneStateListener.LISTEN_NONE) }
        phoneStateReceiver?.let { receiver ->
            runCatching { context.unregisterReceiver(receiver) }
        }
        callback = null
        legacyListener = null
        phoneStateReceiver = null
        currentCallState = TelephonyManager.CALL_STATE_IDLE
        lastIncomingNumber = null
        contactNameCache.clear()
        lastPayload = null
    }

    private fun publishState(callState: Int, number: String?) {
        currentCallState = callState
        val state = when (callState) {
            TelephonyManager.CALL_STATE_RINGING -> "ringing"
            TelephonyManager.CALL_STATE_OFFHOOK -> "active"
            else -> "idle"
        }
        if (state == "idle") {
            lastIncomingNumber = null
            contactNameCache.clear()
        }
        val effectiveNumber = number?.takeIf { it.isNotBlank() } ?: lastIncomingNumber
        val contactName = effectiveNumber?.let { resolvedNumber ->
            contactNameCache.getOrPut(resolvedNumber) {
                PhoneContactLookup.displayNameForNumber(context, resolvedNumber)
            }
        }
        val permissions = PhonePermissions.status(context)
        val payload = JSONObject()
            .put("state", state)
            .put("number", effectiveNumber ?: JSONObject.NULL)
            .put("name", contactName ?: JSONObject.NULL)
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
