package tech.kalkikgp.linkit

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Brings the receiver foreground service back after the process is gone for reasons
 * `START_STICKY` does not cover: a reboot, or the app being updated in place.
 *
 * Only fires when the user actually had the receiver running (`receiverEnabled`) and a
 * Mac is still paired, so an unpaired or explicitly stopped install stays quiet. Starting
 * a `specialUse` foreground service is permitted from these broadcasts, but the start is
 * guarded anyway — a refused start must never crash the app on boot.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED -> Unit
            else -> return
        }
        val app = context.applicationContext
        if (!LinkitPreferences.get(app).receiverEnabled()) return
        if (IdentityStore(app).trustedMac() == null) return
        runCatching { LinkitReceiverService.start(app) }
            .onFailure {
                DebugTelemetry.install(app)
                DebugTelemetry.recordEvent("fgs", "boot restart failed: ${it.message}")
            }
    }
}
