package tech.kalkikgp.linkit

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class LinkitReceiverService : Service() {
    private var receiver: AndroidDropReceiver? = null
    private var phoneCallBridge: PhoneCallBridge? = null
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onCreate() {
        super.onCreate()
        DebugTelemetry.install(applicationContext)
        DebugTelemetry.serviceStarted("LinkitReceiverService")
        ensureChannel()
        startForegroundWithNotification(currentStatus("Listening for Mac drops"))
        val identityStore = IdentityStore(applicationContext)
        val active = AndroidDropReceiver(applicationContext, identityStore) { event ->
            AndroidDropEvents.publish(event)
            updateNotification(event.status)
        }
        active.start()
        receiver = active
        phoneCallBridge = PhoneCallBridge(applicationContext, identityStore, LinkitClient(), serviceScope).also {
            it.start()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            serviceScope.launch {
                val identityStore = IdentityStore(applicationContext)
                identityStore.trustedMac()?.let { mac ->
                    runCatching { LinkitClient().disconnect(mac, identityStore) }
                }
                stopSelf()
            }
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        phoneCallBridge?.stop()
        phoneCallBridge = null
        receiver?.stop()
        receiver = null
        serviceScope.cancel()
        DebugTelemetry.serviceStopped("LinkitReceiverService")
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startForegroundWithNotification(text: String) {
        val notification = buildNotification(text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun updateNotification(text: String) {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification(text))
    }

    private fun buildNotification(text: String): Notification {
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, LinkitReceiverService::class.java).apply { action = ACTION_STOP },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val sendClipboardIntent = PendingIntent.getActivity(
            this,
            2,
            ClipboardActionActivity.intent(this, ClipboardActionActivity.ACTION_SEND_CLIPBOARD),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val openLinkIntent = PendingIntent.getActivity(
            this,
            3,
            ClipboardActionActivity.intent(this, ClipboardActionActivity.ACTION_OPEN_LINK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload_done)
            .setContentTitle("Linkit ready")
            .setContentText(text)
            .setOngoing(true)
            .setSilent(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(openIntent)
            .addAction(0, "Send Clipboard", sendClipboardIntent)
            .addAction(0, "Open Link", openLinkIntent)
            .addAction(0, "Stop", stopIntent)
            .build()
    }

    private fun ensureChannel() {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Linkit receiver",
            NotificationManager.IMPORTANCE_MIN
        ).apply {
            description = "Keeps Linkit ready to receive files from your Mac"
            setShowBadge(false)
            enableLights(false)
            enableVibration(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun currentStatus(default: String): String = default

    companion object {
        private const val CHANNEL_ID = "linkit_receiver"
        private const val NOTIFICATION_ID = 4271
        const val ACTION_STOP = "tech.kalkikgp.linkit.action.STOP_RECEIVER"

        fun start(context: Context) {
            val intent = Intent(context, LinkitReceiverService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, LinkitReceiverService::class.java))
        }
    }
}
