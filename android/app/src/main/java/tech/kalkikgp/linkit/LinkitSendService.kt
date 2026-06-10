package tech.kalkikgp.linkit

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.io.IOException
import java.util.ArrayDeque
import java.util.UUID
import kotlin.math.max
import kotlin.math.roundToLong

class LinkitSendService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val queue = ArrayDeque<Uri>()
    private val queueLock = Any()
    private var workerJob: Job? = null
    private lateinit var identityStore: IdentityStore
    private lateinit var historyStore: TransferHistoryStore
    private val client = LinkitClient()

    override fun onCreate() {
        super.onCreate()
        DebugTelemetry.install(applicationContext)
        DebugTelemetry.serviceStarted("LinkitSendService")
        ensureChannel()
        identityStore = IdentityStore(applicationContext)
        historyStore = TransferHistoryStore.get(applicationContext)
        startForegroundWithProgress("Linkit", "Preparing to send", null, 0, 0)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val uris = intent?.extractUris().orEmpty()
        if (uris.isNotEmpty()) {
            synchronized(queueLock) { uris.forEach(queue::add) }
            ensureWorker()
        } else if (workerJob?.isActive != true && synchronized(queueLock) { queue.isEmpty() }) {
            stopSelfSafely()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        scope.cancel()
        DebugTelemetry.serviceStopped("LinkitSendService")
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun ensureWorker() {
        if (workerJob?.isActive == true) return
        workerJob = scope.launch { runQueue() }
    }

    private suspend fun runQueue() {
        val mac = identityStore.trustedMac()
        if (mac == null) {
            postCompletionNotification("Linkit not paired", "Pair Linkit with your Mac first", success = false)
            stopSelfSafely()
            return
        }
        while (true) {
            val uri = synchronized(queueLock) { queue.pollFirst() } ?: break
            sendOne(mac, uri)
        }
        stopSelfSafely()
    }

    private suspend fun sendOne(mac: TrustedMac, uri: Uri) {
        val file = runCatching { contentResolver.loadPickedFile(uri) }.getOrElse { error ->
            postCompletionNotification("Linkit", "Could not read shared item: ${error.message ?: "unknown"}", success = false)
            return
        }
        val startedAt = SystemClock.elapsedRealtime()
        startForegroundWithProgress(
            title = "Sending to ${mac.deviceName}",
            text = file.name,
            sub = formatSize(file.size),
            progress = 0,
            max = 100
        )
        try {
            val result = client.sendFile(
                contentResolver = contentResolver,
                mac = mac,
                identityStore = identityStore,
                file = file,
                onRetry = { message ->
                    startForegroundWithProgress("Sending to ${mac.deviceName}", file.name, message, 0, 0)
                },
                onProgress = { sent, total ->
                    val elapsed = max(0.001, (SystemClock.elapsedRealtime() - startedAt) / 1000.0)
                    val speed = sent / elapsed
                    val percent = if (total > 0) ((sent * 100) / total).toInt().coerceIn(0, 100) else 0
                    val sub = "${formatSize(sent)} / ${formatSize(total)} · ${formatSize(speed.roundToLong())}/s"
                    startForegroundWithProgress(
                        title = "Sending to ${mac.deviceName}",
                        text = file.name,
                        sub = sub,
                        progress = percent,
                        max = 100
                    )
                }
            )
            historyStore.append(
                TransferHistoryEntry(
                    id = result.transferId,
                    direction = TransferHistoryEntry.DIRECTION_SENT,
                    filename = file.name,
                    size = file.size,
                    peerName = mac.deviceName,
                    completedAt = System.currentTimeMillis(),
                    status = TransferHistoryEntry.STATUS_COMPLETE,
                    savedPath = result.savedPath,
                    error = null
                )
            )
            postCompletionNotification(
                title = "Sent to ${mac.deviceName}",
                text = "${file.name} · ${formatSize(file.size)}",
                success = true
            )
        } catch (io: IOException) {
            recordFailure(mac, file, io.message ?: "Network failed")
        } catch (http: LinkitHttpException) {
            recordFailure(mac, file, http.message)
        } catch (error: Throwable) {
            recordFailure(mac, file, error.message ?: "Send failed")
        }
    }

    private fun recordFailure(mac: TrustedMac, file: PickedFile, message: String) {
        historyStore.append(
            TransferHistoryEntry(
                id = "snd_${UUID.randomUUID()}",
                direction = TransferHistoryEntry.DIRECTION_SENT,
                filename = file.name,
                size = file.size,
                peerName = mac.deviceName,
                completedAt = System.currentTimeMillis(),
                status = TransferHistoryEntry.STATUS_FAILED,
                savedPath = null,
                error = message
            )
        )
        postCompletionNotification(
            title = "Send failed",
            text = "${file.name} · $message",
            success = false
        )
    }

    private fun stopSelfSafely() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun startForegroundWithProgress(title: String, text: String, sub: String?, progress: Int, max: Int) {
        val notification = buildProgressNotification(title, text, sub, progress, max)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(PROGRESS_NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(PROGRESS_NOTIFICATION_ID, notification)
        }
    }

    private fun buildProgressNotification(title: String, text: String, sub: String?, progress: Int, max: Int): Notification {
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle(title)
            .setContentText(text)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setSilent(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(openIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
        sub?.let { builder.setSubText(it) }
        if (max > 0) {
            builder.setProgress(max, progress, false)
        } else {
            builder.setProgress(0, 0, true)
        }
        return builder.build()
    }

    private fun postCompletionNotification(title: String, text: String, success: Boolean) {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val openIntent = PendingIntent.getActivity(
            this,
            1,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = NotificationCompat.Builder(this, CHANNEL_RESULT_ID)
            .setSmallIcon(if (success) android.R.drawable.stat_sys_upload_done else android.R.drawable.stat_notify_error)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setContentIntent(openIntent)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
        manager.notify(System.currentTimeMillis().toInt(), builder.build())
    }

    private fun ensureChannel() {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(CHANNEL_ID, "Linkit sending", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Progress while Linkit sends files to your Mac"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
        if (manager.getNotificationChannel(CHANNEL_RESULT_ID) == null) {
            val channel = NotificationChannel(CHANNEL_RESULT_ID, "Linkit transfers", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Result notifications for Linkit transfers"
            }
            manager.createNotificationChannel(channel)
        }
    }

    private fun formatSize(bytes: Long): String {
        if (bytes < 0) return ""
        val units = arrayOf("B", "KB", "MB", "GB", "TB")
        var value = bytes.toDouble()
        var index = 0
        while (value >= 1024 && index < units.size - 1) {
            value /= 1024.0
            index += 1
        }
        return if (index == 0) "${bytes} B" else "%.1f %s".format(value, units[index])
    }

    companion object {
        private const val CHANNEL_ID = "linkit_sender"
        private const val CHANNEL_RESULT_ID = "linkit_sender_result"
        private const val PROGRESS_NOTIFICATION_ID = 4272
        private const val EXTRA_CONTENT_URIS = "tech.kalkikgp.linkit.extra.CONTENT_URIS"

        fun enqueue(context: Context, uris: List<Uri>) {
            if (uris.isEmpty()) return
            val intent = Intent(context, LinkitSendService::class.java).apply {
                putParcelableArrayListExtra(EXTRA_CONTENT_URIS, ArrayList(uris))
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                clipData = ClipData.newUri(context.contentResolver, "linkit_share", uris.first()).apply {
                    uris.drop(1).forEach { addItem(ClipData.Item(it)) }
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        private fun Intent.extractUris(): List<Uri> {
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                getParcelableArrayListExtra(EXTRA_CONTENT_URIS, Uri::class.java).orEmpty()
            } else {
                @Suppress("DEPRECATION")
                getParcelableArrayListExtra<Uri>(EXTRA_CONTENT_URIS).orEmpty()
            }
        }
    }
}
