package tech.kalkikgp.linkit

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * System-bound listener that mirrors phone notifications to the paired Mac. The OS keeps this
 * service alive (and wakes it on posted notifications even in Doze) once the user grants
 * notification access; the existing foreground service / Wi-Fi lock keeps the network path
 * usable so the signed `notification` action reaches the Mac. Mirroring only happens while the
 * user toggle is on — without it the callbacks no-op.
 */
class NotificationMirrorService : NotificationListenerService() {
    private val client = LinkitClient()
    private lateinit var identityStore: IdentityStore
    private lateinit var preferences: LinkitPreferences
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // Coalesce rapid re-posts of the same notification (progress bars, typing indicators, etc.)
    // so we don't spam the Mac with near-identical banners.
    private val recentlySent = LinkedHashMap<String, Long>()

    override fun onCreate() {
        super.onCreate()
        identityStore = IdentityStore(applicationContext)
        preferences = LinkitPreferences.get(applicationContext)
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        val notification = sbn ?: return
        if (!preferences.settings.value.notificationMirrorEnabled) return
        if (!shouldMirror(notification)) return

        val appName = appLabel(notification.packageName)
        val extras = notification.notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_TEXT))
            ?.toString()?.trim().orEmpty()
        if (title.isBlank() && text.isBlank()) return

        val dedupeKey = "${notification.packageName}|${notification.id}|$title|$text"
        val now = System.currentTimeMillis()
        pruneRecentlySent(now)
        if (recentlySent.put(dedupeKey, now) != null) return

        val payload = JSONObject()
            .put("appName", appName)
            .put("title", title)
            .put("text", text)
            .put("postedAtMillis", now)
            .toString()

        scope.launch {
            val mac = identityStore.trustedMac() ?: return@launch
            runCatching {
                client.sendAction(mac, identityStore, "notification", payload)
            }.onSuccess {
                DebugTelemetry.recordEvent("notif", "mirrored ${notification.packageName}")
            }.onFailure { error ->
                DebugTelemetry.recordEvent("notif", "mirror send failed: ${error.message}")
            }
        }
    }

    private fun shouldMirror(sbn: StatusBarNotification): Boolean {
        if (sbn.packageName == applicationContext.packageName) return false
        val flags = sbn.notification.flags
        if (flags and Notification.FLAG_ONGOING_EVENT != 0) return false
        if (flags and Notification.FLAG_FOREGROUND_SERVICE != 0) return false
        if (flags and Notification.FLAG_GROUP_SUMMARY != 0) return false
        if (!sbn.isClearable) return false
        return true
    }

    private fun appLabel(packageName: String): String = runCatching {
        val pm = applicationContext.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(packageName, 0)).toString()
    }.getOrDefault(packageName)

    private fun pruneRecentlySent(now: Long) {
        val iterator = recentlySent.entries.iterator()
        while (iterator.hasNext()) {
            if (now - iterator.next().value > DEDUPE_WINDOW_MS) iterator.remove()
        }
        while (recentlySent.size > MAX_DEDUPE_ENTRIES) {
            val oldest = recentlySent.keys.firstOrNull() ?: break
            recentlySent.remove(oldest)
        }
    }

    companion object {
        private const val DEDUPE_WINDOW_MS = 5_000L
        private const val MAX_DEDUPE_ENTRIES = 64
    }
}

/** Helpers for the OS notification-access grant that [NotificationMirrorService] depends on. */
object NotificationAccess {
    fun isGranted(context: Context): Boolean {
        val enabled = Settings.Secure.getString(
            context.contentResolver,
            "enabled_notification_listeners"
        ) ?: return false
        val component = ComponentName(context, NotificationMirrorService::class.java)
        return enabled.split(':').any {
            val parsed = ComponentName.unflattenFromString(it)
            parsed == component || parsed?.packageName == context.packageName &&
                parsed.className == component.className
        }
    }

    fun settingsIntent(): Intent =
        Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
}
