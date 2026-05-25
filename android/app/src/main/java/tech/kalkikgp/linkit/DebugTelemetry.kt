package tech.kalkikgp.linkit

import android.content.Context
import android.net.TrafficStats
import android.os.BatteryManager
import android.os.Process
import android.os.SystemClock
import android.util.Log
import java.text.SimpleDateFormat
import java.util.ArrayDeque
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

object DebugTelemetry {
    private const val MAX_LOG_LINES = 500
    private const val MAX_EVENTS = 120

    enum class Level { D, I, W, E }

    data class LogEntry(
        val timestampMillis: Long,
        val level: Level,
        val tag: String,
        val message: String
    )

    data class EventEntry(
        val timestampMillis: Long,
        val category: String,
        val detail: String
    )

    data class BatterySample(
        val timestampMillis: Long,
        val percent: Int,
        val reason: String
    )

    data class ServiceWindow(
        val name: String,
        val startedAtMillis: Long,
        val endedAtMillis: Long?
    ) {
        fun durationMillis(now: Long = System.currentTimeMillis()): Long =
            (endedAtMillis ?: now) - startedAtMillis
    }

    data class Snapshot(
        val capturedAtMillis: Long,
        val uid: Int,
        val pid: Int,
        val cpuMillisSinceProcessStart: Long,
        val cpuMillisSinceBaseline: Long,
        val processUptimeMillis: Long,
        val rxBytesSinceProcessStart: Long,
        val txBytesSinceProcessStart: Long,
        val rxBytesSinceBaseline: Long,
        val txBytesSinceBaseline: Long,
        val batteryPercent: Int?,
        val batteryAtBaselinePercent: Int?,
        val baselineCapturedAtMillis: Long,
        val activeServices: List<ServiceWindow>,
        val completedServices: List<ServiceWindow>,
        val events: List<EventEntry>,
        val logs: List<LogEntry>,
        val batterySamples: List<BatterySample>
    )

    private val processStartMillis: Long = System.currentTimeMillis()
    private val processStartCpuMillis: Long = Process.getElapsedCpuTime()
    private val pid: Int = Process.myPid()
    private val uid: Int = Process.myUid()

    private val logBuffer = ArrayDeque<LogEntry>()
    private val eventBuffer = ArrayDeque<EventEntry>()
    private val batterySamples = ArrayDeque<BatterySample>()
    private val activeServices = LinkedHashMap<String, ServiceWindow>()
    private val completedServices = ArrayDeque<ServiceWindow>()

    private var appContext: Context? = null

    private val processStartRxBytes: Long = TrafficStats.getUidRxBytes(uid).coerceAtLeast(0L)
    private val processStartTxBytes: Long = TrafficStats.getUidTxBytes(uid).coerceAtLeast(0L)

    private var baselineCapturedAtMillis: Long = processStartMillis
    private var baselineCpuMillis: Long = processStartCpuMillis
    private var baselineRxBytes: Long = processStartRxBytes
    private var baselineTxBytes: Long = processStartTxBytes
    private var baselineBatteryPercent: Int? = null

    private val _snapshotTick = MutableStateFlow(0L)
    val snapshotTick: StateFlow<Long> = _snapshotTick.asStateFlow()

    @Synchronized
    fun install(context: Context) {
        if (appContext != null) return
        appContext = context.applicationContext
        baselineBatteryPercent = readBatteryPercent()
        sampleBattery("baseline")
        log("Debug", Level.I, "Telemetry installed pid=$pid uid=$uid")
    }

    @Synchronized
    fun log(tag: String, level: Level, message: String) {
        when (level) {
            Level.D -> Log.d(tag, message)
            Level.I -> Log.i(tag, message)
            Level.W -> Log.w(tag, message)
            Level.E -> Log.e(tag, message)
        }
        logBuffer.addLast(LogEntry(System.currentTimeMillis(), level, tag, message))
        while (logBuffer.size > MAX_LOG_LINES) logBuffer.removeFirst()
        bumpTick()
    }

    fun d(tag: String, message: String) = log(tag, Level.D, message)
    fun i(tag: String, message: String) = log(tag, Level.I, message)
    fun w(tag: String, message: String) = log(tag, Level.W, message)
    fun e(tag: String, message: String) = log(tag, Level.E, message)

    @Synchronized
    fun recordEvent(category: String, detail: String) {
        eventBuffer.addLast(EventEntry(System.currentTimeMillis(), category, detail))
        while (eventBuffer.size > MAX_EVENTS) eventBuffer.removeFirst()
        bumpTick()
    }

    @Synchronized
    fun serviceStarted(name: String) {
        if (activeServices.containsKey(name)) return
        val window = ServiceWindow(name, System.currentTimeMillis(), null)
        activeServices[name] = window
        sampleBattery("$name start")
        recordEvent("fgs", "$name started")
    }

    @Synchronized
    fun serviceStopped(name: String) {
        val window = activeServices.remove(name) ?: return
        val closed = window.copy(endedAtMillis = System.currentTimeMillis())
        completedServices.addLast(closed)
        while (completedServices.size > 30) completedServices.removeFirst()
        sampleBattery("$name stop")
        recordEvent("fgs", "$name stopped after ${debugFormatDuration(closed.durationMillis())}")
    }

    @Synchronized
    fun resetBaseline() {
        baselineCapturedAtMillis = System.currentTimeMillis()
        baselineCpuMillis = Process.getElapsedCpuTime()
        baselineRxBytes = TrafficStats.getUidRxBytes(uid).coerceAtLeast(0L)
        baselineTxBytes = TrafficStats.getUidTxBytes(uid).coerceAtLeast(0L)
        baselineBatteryPercent = readBatteryPercent()
        sampleBattery("baseline reset")
        recordEvent("debug", "Baseline reset")
    }

    @Synchronized
    fun clearLogs() {
        logBuffer.clear()
        bumpTick()
    }

    @Synchronized
    fun snapshot(): Snapshot {
        val now = System.currentTimeMillis()
        val cpuNow = Process.getElapsedCpuTime()
        val rxNow = TrafficStats.getUidRxBytes(uid).coerceAtLeast(0L)
        val txNow = TrafficStats.getUidTxBytes(uid).coerceAtLeast(0L)
        return Snapshot(
            capturedAtMillis = now,
            uid = uid,
            pid = pid,
            cpuMillisSinceProcessStart = cpuNow - processStartCpuMillis,
            cpuMillisSinceBaseline = cpuNow - baselineCpuMillis,
            processUptimeMillis = now - processStartMillis,
            rxBytesSinceProcessStart = (rxNow - processStartRxBytes).coerceAtLeast(0L),
            txBytesSinceProcessStart = (txNow - processStartTxBytes).coerceAtLeast(0L),
            rxBytesSinceBaseline = (rxNow - baselineRxBytes).coerceAtLeast(0L),
            txBytesSinceBaseline = (txNow - baselineTxBytes).coerceAtLeast(0L),
            batteryPercent = readBatteryPercent(),
            batteryAtBaselinePercent = baselineBatteryPercent,
            baselineCapturedAtMillis = baselineCapturedAtMillis,
            activeServices = activeServices.values.toList(),
            completedServices = completedServices.toList(),
            events = eventBuffer.toList(),
            logs = logBuffer.toList(),
            batterySamples = batterySamples.toList()
        )
    }

    fun adbBatteryStatsCommand(): String =
        "adb shell dumpsys batterystats --charged tech.kalkikgp.linkit"

    private fun bumpTick() {
        _snapshotTick.value = SystemClock.elapsedRealtimeNanos()
    }

    private fun sampleBattery(reason: String) {
        val percent = readBatteryPercent() ?: return
        batterySamples.addLast(BatterySample(System.currentTimeMillis(), percent, reason))
        while (batterySamples.size > 60) batterySamples.removeFirst()
    }

    private fun readBatteryPercent(): Int? {
        val ctx = appContext ?: return null
        val bm = ctx.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager ?: return null
        val raw = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        return if (raw in 0..100) raw else null
    }
}

internal fun debugFormatDuration(millis: Long): String {
    val safe = millis.coerceAtLeast(0L)
    val seconds = safe / 1000
    val h = seconds / 3600
    val m = (seconds % 3600) / 60
    val s = seconds % 60
    return when {
        h > 0 -> String.format(Locale.US, "%dh %02dm %02ds", h, m, s)
        m > 0 -> String.format(Locale.US, "%dm %02ds", m, s)
        else -> String.format(Locale.US, "%ds", s)
    }
}

internal fun debugFormatBytes(bytes: Long): String {
    val safe = bytes.coerceAtLeast(0L)
    val kib = 1024.0
    return when {
        safe >= kib * kib * kib -> String.format(Locale.US, "%.2f GB", safe / (kib * kib * kib))
        safe >= kib * kib -> String.format(Locale.US, "%.2f MB", safe / (kib * kib))
        safe >= kib -> String.format(Locale.US, "%.1f KB", safe / kib)
        else -> "$safe B"
    }
}

internal fun debugFormatTimestamp(millis: Long): String =
    SimpleDateFormat("HH:mm:ss.SSS", Locale.US).format(Date(millis))

internal fun debugFormatDateTime(millis: Long): String =
    SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date(millis))
