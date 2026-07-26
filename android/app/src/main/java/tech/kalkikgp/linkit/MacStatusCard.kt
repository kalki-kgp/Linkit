package tech.kalkikgp.linkit

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.BatteryChargingFull
import androidx.compose.material.icons.rounded.BatteryFull
import androidx.compose.material.icons.rounded.Storage
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.DoNotDisturbOn
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Power
import androidx.compose.material.icons.rounded.Lan
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Wifi
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import kotlinx.coroutines.delay
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * The Home screen's hero: the paired Mac rendered as a device, plus a strip of live readings
 * the Mac reports about itself on every registration refresh (~20s).
 *
 * This is the mirror image of the Mac's own popover, which shows the phone's battery — the
 * phone now knows as much about the Mac as the Mac knows about the phone.
 */
@Composable
fun MacStatusCard(
    state: LinkitUiState,
    onReconnect: () -> Unit,
    onOpenDeviceSettings: () -> Unit
) {
    val mac = state.trustedMac ?: return
    val accent = MaterialTheme.colorScheme.primary
    val status = state.macStatus

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(22.dp))
            .background(MaterialTheme.colorScheme.surface)
            .border(
                BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                RoundedCornerShape(22.dp)
            )
    ) {
        // Hero — the device itself, on an accent wash that reads as "this machine is alive".
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(
                    Brush.verticalGradient(
                        listOf(
                            accent.copy(alpha = if (state.isConnectedToMac) 0.20f else 0.06f),
                            MaterialTheme.colorScheme.surface
                        )
                    )
                )
                .padding(top = 18.dp, bottom = 16.dp)
        ) {
            IconButton(
                onClick = onOpenDeviceSettings,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(end = 8.dp)
                    .size(34.dp)
            ) {
                Icon(
                    imageVector = Icons.Rounded.Settings,
                    contentDescription = "Device settings",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(19.dp)
                )
            }

            Column(
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                MacBookGlyph(accent = accent, connected = state.isConnectedToMac)
                Text(
                    mac.deviceName,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(horizontal = 44.dp)
                )
                MacStatusLine(state)
                MacBadges(status)
            }
        }

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(1.dp)
                .background(MaterialTheme.colorScheme.outlineVariant)
        )

        MacMetricStrip(state = state, status = status)

        if (!state.isConnectedToMac) {
            Button(
                onClick = onReconnect,
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = accent,
                    contentColor = MaterialTheme.colorScheme.onPrimary
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 14.dp, end = 14.dp, bottom = 14.dp)
                    .heightIn(min = 46.dp)
            ) {
                val isWorking = state.status.startsWith("Looking") ||
                    state.status.startsWith("Connecting") ||
                    state.status.startsWith("Trying")
                Text(
                    if (isWorking) state.status else "Reconnect",
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.Medium
                )
            }
        }
    }
}

/**
 * A laptop drawn rather than iconified, so the card has a real subject at the top the way the
 * Mac's own panel does. Vector shapes only — no bitmap asset to ship or theme.
 */
@Composable
internal fun MacBookGlyph(
    accent: Color,
    connected: Boolean,
    width: Dp = 96.dp,
    height: Dp = 62.dp
) {
    val screenTint = if (connected) accent else MaterialTheme.colorScheme.outline
    val body = MaterialTheme.colorScheme.onSurfaceVariant
    androidx.compose.foundation.Canvas(
        modifier = Modifier
            .width(width)
            .height(height)
    ) {
        drawMacBook(screenTint = screenTint, bodyTint = body)
    }
}

private fun DrawScope.drawMacBook(screenTint: Color, bodyTint: Color) {
    val lidHeight = size.height * 0.74f
    val lidWidth = size.width * 0.78f
    val lidLeft = (size.width - lidWidth) / 2f
    val bezel = size.width * 0.022f

    // Lid: outer shell, then the illuminated display inset inside it.
    drawRoundRect(
        color = bodyTint.copy(alpha = 0.55f),
        topLeft = Offset(lidLeft, 0f),
        size = Size(lidWidth, lidHeight),
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(size.width * 0.035f)
    )
    drawRoundRect(
        brush = Brush.linearGradient(
            colors = listOf(screenTint, screenTint.copy(alpha = 0.45f)),
            start = Offset(lidLeft, 0f),
            end = Offset(lidLeft + lidWidth, lidHeight)
        ),
        topLeft = Offset(lidLeft + bezel, bezel),
        size = Size(lidWidth - bezel * 2, lidHeight - bezel * 2),
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(size.width * 0.022f)
    )

    // Base: the full-width deck the lid sits on, with a notch for the trackpad lip.
    val baseTop = lidHeight + size.height * 0.03f
    val baseHeight = size.height * 0.09f
    drawRoundRect(
        color = bodyTint.copy(alpha = 0.7f),
        topLeft = Offset(0f, baseTop),
        size = Size(size.width, baseHeight),
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(baseHeight / 2f)
    )
    drawRoundRect(
        color = bodyTint.copy(alpha = 0.95f),
        topLeft = Offset(size.width * 0.43f, baseTop),
        size = Size(size.width * 0.14f, baseHeight * 0.5f),
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(baseHeight * 0.25f)
    )
}

@Composable
private fun MacStatusLine(state: LinkitUiState) {
    val connecting = state.status.startsWith("Looking") ||
        state.status.startsWith("Connecting") ||
        state.status.startsWith("Trying") ||
        state.status.startsWith("Disconnecting") ||
        state.status == "Discovering"
    val label: String
    val dotColor: Color
    val animated: Boolean
    when {
        state.isConnectedToMac -> {
            label = "Connected"
            dotColor = MaterialTheme.colorScheme.tertiary
            animated = true
        }
        connecting -> {
            label = state.status
            dotColor = MaterialTheme.colorScheme.primary
            animated = true
        }
        else -> {
            label = "Offline"
            dotColor = MaterialTheme.colorScheme.outline
            animated = false
        }
    }
    Row(
        horizontalArrangement = Arrangement.spacedBy(7.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        StatusPulseDot(color = dotColor, animated = animated)
        Text(
            label,
            fontSize = 13.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}

@Composable
fun StatusPulseDot(color: Color, animated: Boolean, size: Int = 8) {
    val alpha = if (animated) {
        val transition = rememberInfiniteTransition(label = "status-pulse")
        transition.animateFloat(
            initialValue = 1f,
            targetValue = 0.35f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = 1400, easing = LinearEasing),
                repeatMode = RepeatMode.Reverse
            ),
            label = "alpha"
        ).value
    } else 1f
    Box(
        modifier = Modifier
            .size(size.dp)
            .clip(CircleShape)
            .background(color.copy(alpha = alpha))
    )
}

/**
 * Conditions worth knowing about but not worth a permanent slot: they explain surprises
 * ("why didn't my notification show up on the Mac?") and vanish when they don't apply.
 */
@Composable
private fun MacBadges(status: MacSystemStatus?) {
    if (status == null) return
    val badges = buildList {
        if (status.doNotDisturb) add(Icons.Rounded.DoNotDisturbOn to "Do Not Disturb")
        if (status.lowPowerMode) add(Icons.Rounded.Bolt to "Low Power")
    }
    if (badges.isEmpty()) return
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        badges.forEach { (icon, label) -> MacBadge(icon = icon, label = label) }
    }
}

@Composable
private fun MacBadge(icon: ImageVector, label: String) {
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(horizontal = 9.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(12.dp)
        )
        Text(
            label,
            fontSize = 10.sp,
            fontWeight = FontWeight.Medium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

/** The four readings, in the order they matter before you send something to the Mac. */
@Composable
private fun MacMetricStrip(state: LinkitUiState, status: MacSystemStatus?) {
    val stale = !state.isConnectedToMac
    // Read here so the whole strip recomposes on the tick: once the Mac stops answering,
    // `macLastSeenMillis` stops changing too, and a frozen "Just now" would be a lie exactly
    // when the growing age is the useful part.
    rememberTicker()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 13.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp)
    ) {
        val battery = batteryMetric(status)
        MacMetric(
            modifier = Modifier.weight(1f),
            icon = battery.icon,
            value = battery.value,
            label = battery.label,
            tint = battery.tint,
            dimmed = stale
        )
        val network = networkMetric(status)
        MacMetric(
            modifier = Modifier.weight(1f),
            icon = network.icon,
            value = network.value,
            label = network.label,
            tint = network.tint,
            dimmed = stale
        )
        MacMetric(
            modifier = Modifier.weight(1f),
            icon = Icons.Rounded.Storage,
            value = status?.freeDiskBytes?.let { formatBytes(it) } ?: "—",
            label = "Free",
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            dimmed = stale
        )
        MacMetric(
            modifier = Modifier.weight(1f),
            icon = Icons.Rounded.History,
            value = state.macLastSeenMillis
                ?.let { formatRelative(it).replaceFirstChar { c -> c.uppercase() } }
                ?: "—",
            label = "Last sync",
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            dimmed = stale
        )
    }
}

/**
 * Advances a counter every 30s while composed. Returning a value makes this non-restartable, so
 * the state read propagates to the caller's scope — which is the point: the caller recomposes and
 * its relative timestamps age on their own.
 */
@Composable
private fun rememberTicker(): Int {
    var tick by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(30_000)
            tick += 1
        }
    }
    return tick
}

private data class MetricVisual(
    val icon: ImageVector,
    val value: String,
    val label: String,
    val tint: Color
)

@Composable
private fun batteryMetric(status: MacSystemStatus?): MetricVisual {
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    val good = MaterialTheme.colorScheme.tertiary
    val warn = MaterialTheme.colorScheme.error
    val percent = status?.batteryPercent
        ?: return MetricVisual(
            // No battery entry at all: a desktop Mac, which is simply always on wall power.
            icon = if (status?.isOnAcPower == true) Icons.Rounded.Power else Icons.Rounded.BatteryFull,
            value = if (status?.isOnAcPower == true) "AC" else "—",
            label = "Power",
            tint = if (status?.isOnAcPower == true) good else muted
        )
    val charging = status.isCharging == true
    return MetricVisual(
        icon = if (charging) Icons.Rounded.BatteryChargingFull else Icons.Rounded.BatteryFull,
        value = "$percent%",
        label = when {
            charging -> "Charging"
            status.isOnAcPower -> "Plugged in"
            else -> "Battery"
        },
        // Only shout when the Mac is genuinely running low *and* not being fed.
        tint = when {
            charging -> good
            percent <= 20 && !status.isOnAcPower -> warn
            else -> muted
        }
    )
}

@Composable
private fun networkMetric(status: MacSystemStatus?): MetricVisual {
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    if (status?.networkKind == "ethernet") {
        return MetricVisual(Icons.Rounded.Lan, "Wired", "Network", muted)
    }
    val quality = status?.wifiQuality
    return MetricVisual(
        icon = Icons.Rounded.Wifi,
        // Without a usable RSSI the honest answer is just "on Wi-Fi", not a made-up rating.
        value = quality?.replaceFirstChar { it.uppercase() } ?: if (status == null) "—" else "On",
        label = "Wi-Fi",
        tint = when (quality) {
            "excellent", "good" -> MaterialTheme.colorScheme.tertiary
            "weak" -> MaterialTheme.colorScheme.error
            else -> muted
        }
    )
}

@Composable
private fun MacMetric(
    modifier: Modifier,
    icon: ImageVector,
    value: String,
    label: String,
    tint: Color,
    dimmed: Boolean
) {
    val alpha = if (dimmed) 0.42f else 1f
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp)
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(3.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = tint.copy(alpha = alpha),
                modifier = Modifier.size(14.dp)
            )
            Text(
                value,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = alpha),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
        Text(
            label,
            fontSize = 10.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = alpha),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}
