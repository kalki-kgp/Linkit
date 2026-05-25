package tech.kalkikgp.linkit

import android.content.ClipData
import android.content.ClipboardManager
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay

class DebugActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        DebugTelemetry.install(applicationContext)
        setContent {
            LinkitDebugTheme {
                DebugScreen(onClose = { finish() })
            }
        }
    }
}

@Composable
private fun LinkitDebugTheme(content: @Composable () -> Unit) {
    val colors = androidx.compose.material3.lightColorScheme(
        primary = Color(0xFF1F2937),
        onPrimary = Color.White,
        background = Color(0xFFF5F4EF),
        onBackground = Color(0xFF111827),
        surface = Color(0xFFFFFFFF),
        onSurface = Color(0xFF111827),
        surfaceVariant = Color(0xFFEAE6DD),
        onSurfaceVariant = Color(0xFF4B5563),
        outline = Color(0xFFD6D2C7),
        outlineVariant = Color(0xFFE3DFD3)
    )
    androidx.compose.material3.MaterialTheme(colorScheme = colors, content = content)
}

@Composable
private fun DebugScreen(onClose: () -> Unit) {
    var snapshot by remember { mutableStateOf(DebugTelemetry.snapshot()) }
    LaunchedEffect(Unit) {
        while (true) {
            snapshot = DebugTelemetry.snapshot()
            delay(2_000)
        }
    }
    val context = LocalContext.current

    Surface(
        modifier = Modifier.fillMaxSize(),
        color = MaterialTheme.colorScheme.background
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .systemBarsPadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 12.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    "Debug",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.SemiBold
                )
                TextButton(onClick = onClose) { Text("Close") }
            }
            Spacer(Modifier.height(8.dp))

            Section(title = "Process") {
                KeyValue("uid / pid", "${snapshot.uid} / ${snapshot.pid}")
                KeyValue("Process uptime", debugFormatDuration(snapshot.processUptimeMillis))
                KeyValue(
                    "CPU (since start)",
                    "${debugFormatDuration(snapshot.cpuMillisSinceProcessStart)} (${cpuPercent(snapshot.cpuMillisSinceProcessStart, snapshot.processUptimeMillis)})"
                )
                val baselineWindow = snapshot.capturedAtMillis - snapshot.baselineCapturedAtMillis
                KeyValue(
                    "CPU (since baseline)",
                    "${debugFormatDuration(snapshot.cpuMillisSinceBaseline)} (${cpuPercent(snapshot.cpuMillisSinceBaseline, baselineWindow)})"
                )
            }

            Section(title = "Network (this UID)") {
                KeyValue("Rx since start", debugFormatBytes(snapshot.rxBytesSinceProcessStart))
                KeyValue("Tx since start", debugFormatBytes(snapshot.txBytesSinceProcessStart))
                KeyValue("Rx since baseline", debugFormatBytes(snapshot.rxBytesSinceBaseline))
                KeyValue("Tx since baseline", debugFormatBytes(snapshot.txBytesSinceBaseline))
            }

            Section(title = "Battery") {
                KeyValue("Now", snapshot.batteryPercent?.let { "$it%" } ?: "unknown")
                KeyValue("At baseline", snapshot.batteryAtBaselinePercent?.let { "$it%" } ?: "unknown")
                val delta = batteryDelta(snapshot.batteryAtBaselinePercent, snapshot.batteryPercent)
                KeyValue("Delta", delta)
                KeyValue("Baseline taken", debugFormatDateTime(snapshot.baselineCapturedAtMillis))
                if (snapshot.batterySamples.isNotEmpty()) {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Samples",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    snapshot.batterySamples.takeLast(8).asReversed().forEach { s ->
                        MonoLine("${debugFormatTimestamp(s.timestampMillis)}  ${s.percent}%  ${s.reason}")
                    }
                }
            }

            Section(title = "Foreground services") {
                if (snapshot.activeServices.isEmpty() && snapshot.completedServices.isEmpty()) {
                    Text(
                        "No service windows recorded yet.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                snapshot.activeServices.forEach { w ->
                    MonoLine("• ${w.name}  (running ${debugFormatDuration(w.durationMillis(snapshot.capturedAtMillis))})")
                }
                snapshot.completedServices.takeLast(8).asReversed().forEach { w ->
                    MonoLine("  ${w.name}  ${debugFormatDuration(w.durationMillis(snapshot.capturedAtMillis))}  ended ${debugFormatTimestamp(w.endedAtMillis ?: 0)}")
                }
            }

            Section(title = "Events") {
                if (snapshot.events.isEmpty()) {
                    Text(
                        "No events yet.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                snapshot.events.takeLast(40).asReversed().forEach { e ->
                    MonoLine("${debugFormatTimestamp(e.timestampMillis)}  [${e.category}] ${e.detail}")
                }
            }

            Section(title = "Logs (last ${snapshot.logs.size})") {
                if (snapshot.logs.isEmpty()) {
                    Text(
                        "Log ring is empty.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                snapshot.logs.takeLast(80).asReversed().forEach { entry ->
                    MonoLine("${debugFormatTimestamp(entry.timestampMillis)} ${entry.level.name} ${entry.tag}: ${entry.message}")
                }
            }

            Spacer(Modifier.height(16.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Button(
                    onClick = {
                        DebugTelemetry.resetBaseline()
                        snapshot = DebugTelemetry.snapshot()
                        Toast.makeText(context, "Baseline reset", Toast.LENGTH_SHORT).show()
                    },
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = MaterialTheme.colorScheme.surface,
                        contentColor = MaterialTheme.colorScheme.onSurface
                    )
                ) { Text("Reset baseline") }
                Button(
                    onClick = {
                        DebugTelemetry.clearLogs()
                        snapshot = DebugTelemetry.snapshot()
                    },
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = MaterialTheme.colorScheme.surface,
                        contentColor = MaterialTheme.colorScheme.onSurface
                    )
                ) { Text("Clear logs") }
            }
            Spacer(Modifier.height(8.dp))
            Button(
                onClick = {
                    val report = buildReport(snapshot)
                    copyToClipboard(context, "Linkit debug report", report)
                    Toast.makeText(context, "Report copied", Toast.LENGTH_SHORT).show()
                },
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp)
            ) { Text("Copy full report") }
            Spacer(Modifier.height(8.dp))
            Button(
                onClick = {
                    copyToClipboard(context, "adb batterystats", DebugTelemetry.adbBatteryStatsCommand())
                    Toast.makeText(context, "adb command copied", Toast.LENGTH_SHORT).show()
                },
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = MaterialTheme.colorScheme.surface,
                    contentColor = MaterialTheme.colorScheme.onSurface
                )
            ) { Text("Copy `adb dumpsys batterystats` command") }
            Spacer(Modifier.height(24.dp))
            Text(
                "Note: in-app battery readings are system % at sample time. For per-app mAh, run the copied adb command on a host machine.",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(Modifier.height(16.dp))
        }
    }
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Spacer(Modifier.height(12.dp))
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surface)
            .border(
                androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                RoundedCornerShape(16.dp)
            )
            .padding(14.dp)
    ) {
        Text(
            title,
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold
        )
        Spacer(Modifier.height(8.dp))
        content()
    }
}

@Composable
private fun KeyValue(key: String, value: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 22.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            key,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(
            value,
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurface
        )
    }
}

@Composable
private fun MonoLine(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall.copy(fontSize = 11.sp),
        fontFamily = FontFamily.Monospace,
        color = MaterialTheme.colorScheme.onSurface
    )
}

private fun cpuPercent(cpuMillis: Long, windowMillis: Long): String {
    if (windowMillis <= 0) return "—"
    val pct = (cpuMillis.toDouble() / windowMillis.toDouble()) * 100.0
    return String.format(java.util.Locale.US, "%.2f%% of wall", pct)
}

private fun batteryDelta(start: Int?, end: Int?): String {
    if (start == null || end == null) return "—"
    val delta = end - start
    val sign = when {
        delta > 0 -> "+"
        delta < 0 -> ""
        else -> "±"
    }
    return "$sign$delta%"
}

private fun copyToClipboard(context: android.content.Context, label: String, text: String) {
    val cm = context.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as ClipboardManager
    cm.setPrimaryClip(ClipData.newPlainText(label, text))
}

private fun buildReport(snapshot: DebugTelemetry.Snapshot): String {
    val sb = StringBuilder()
    sb.appendLine("Linkit debug report")
    sb.appendLine("Captured: ${debugFormatDateTime(snapshot.capturedAtMillis)}")
    sb.appendLine("uid=${snapshot.uid} pid=${snapshot.pid}")
    sb.appendLine()
    sb.appendLine("Process uptime: ${debugFormatDuration(snapshot.processUptimeMillis)}")
    sb.appendLine("CPU since start: ${debugFormatDuration(snapshot.cpuMillisSinceProcessStart)} (${cpuPercent(snapshot.cpuMillisSinceProcessStart, snapshot.processUptimeMillis)})")
    val baselineWindow = snapshot.capturedAtMillis - snapshot.baselineCapturedAtMillis
    sb.appendLine("CPU since baseline: ${debugFormatDuration(snapshot.cpuMillisSinceBaseline)} (${cpuPercent(snapshot.cpuMillisSinceBaseline, baselineWindow)})")
    sb.appendLine()
    sb.appendLine("Network (this UID):")
    sb.appendLine("  Rx since start: ${debugFormatBytes(snapshot.rxBytesSinceProcessStart)}")
    sb.appendLine("  Tx since start: ${debugFormatBytes(snapshot.txBytesSinceProcessStart)}")
    sb.appendLine("  Rx since baseline: ${debugFormatBytes(snapshot.rxBytesSinceBaseline)}")
    sb.appendLine("  Tx since baseline: ${debugFormatBytes(snapshot.txBytesSinceBaseline)}")
    sb.appendLine()
    sb.appendLine("Battery: now=${snapshot.batteryPercent ?: "?"}% baseline=${snapshot.batteryAtBaselinePercent ?: "?"}% delta=${batteryDelta(snapshot.batteryAtBaselinePercent, snapshot.batteryPercent)}")
    sb.appendLine()
    sb.appendLine("Active services:")
    snapshot.activeServices.forEach { sb.appendLine("  ${it.name} running ${debugFormatDuration(it.durationMillis(snapshot.capturedAtMillis))}") }
    sb.appendLine("Completed services (last 8):")
    snapshot.completedServices.takeLast(8).forEach {
        sb.appendLine("  ${it.name} ${debugFormatDuration(it.durationMillis(snapshot.capturedAtMillis))}")
    }
    sb.appendLine()
    sb.appendLine("Events (last 40):")
    snapshot.events.takeLast(40).forEach {
        sb.appendLine("  ${debugFormatTimestamp(it.timestampMillis)} [${it.category}] ${it.detail}")
    }
    sb.appendLine()
    sb.appendLine("Logs (last 80):")
    snapshot.logs.takeLast(80).forEach {
        sb.appendLine("  ${debugFormatTimestamp(it.timestampMillis)} ${it.level.name} ${it.tag}: ${it.message}")
    }
    return sb.toString()
}
