package tech.kalkikgp.linkit

import android.os.Build
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.Call
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.Palette
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * The Settings hub: the pairing itself as a hero, then categories that drill into detail screens.
 *
 * Every category row reports its **live** state on the right — "On", "Needs attention", the
 * current accent name. The point is that you can read the whole configuration without opening
 * anything, and a broken feature announces itself here instead of hiding one level down.
 */
@Composable
fun SettingsHubScreen(
    state: LinkitUiState,
    settings: LinkitSettings,
    onOpenDetail: (SettingsRoute) -> Unit
) {
    val accent = MaterialTheme.colorScheme.primary
    Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
        LinkitLargeHeader(title = "Settings", subtitle = "Manage your Linkit connection and preferences.")

        PairedDevicesHero(state = state, onClick = { onOpenDetail(SettingsRoute.DEVICE) })

        SettingsGroupCard(label = "Features") {
            SettingsHubRow(
                icon = Icons.Rounded.ContentPaste,
                title = "Clipboard",
                subtitle = "Sync copied text between devices.",
                status = state.hubStatus(AndroidFeatureStatus.ID_CLIPBOARD_SYNC),
                accent = accent
            ) { onOpenDetail(SettingsRoute.CLIPBOARD) }
            LinkitRowDivider()
            SettingsHubRow(
                icon = Icons.Rounded.Notifications,
                title = "Notifications",
                subtitle = "Mirror phone notifications to the Mac.",
                status = state.hubStatus(AndroidFeatureStatus.ID_NOTIFICATION_MIRROR),
                accent = accent
            ) { onOpenDetail(SettingsRoute.NOTIFICATIONS) }
            LinkitRowDivider()
            SettingsHubRow(
                icon = Icons.Rounded.Call,
                title = "Phone",
                subtitle = "Call control permissions and caller ID.",
                status = state.hubStatus(AndroidFeatureStatus.ID_PHONE_CONTROL),
                accent = accent
            ) { onOpenDetail(SettingsRoute.PHONE) }
        }

        SettingsGroupCard(label = "App") {
            SettingsHubRow(
                icon = Icons.Rounded.Palette,
                title = "Appearance",
                subtitle = "Accent color and light or dark theme.",
                status = HubStatus(
                    label = LinkitAccents.nameFor(settings.accentColorHex).substringBefore(" ("),
                    tone = HubTone.NEUTRAL
                ),
                accent = accent
            ) { onOpenDetail(SettingsRoute.APPEARANCE) }
            LinkitRowDivider()
            SettingsHubRow(
                icon = Icons.Rounded.Bolt,
                title = "Background & battery",
                subtitle = "Keep Linkit reachable while the screen is off.",
                // The receiver being alive matters more than the exemption, so a stopped
                // receiver wins the row even when the exemption is granted.
                status = state.hubStatus(AndroidFeatureStatus.ID_RECEIVER)
                    .takeIf { it.tone == HubTone.ATTENTION }
                    ?: state.hubStatus(AndroidFeatureStatus.ID_BATTERY),
                accent = accent
            ) { onOpenDetail(SettingsRoute.BACKGROUND) }
            LinkitRowDivider()
            SettingsHubRow(
                icon = Icons.Rounded.Download,
                title = "Updates",
                subtitle = "Check for a newer Linkit build.",
                status = updateStatus(state),
                accent = accent
            ) { onOpenDetail(SettingsRoute.UPDATES) }
            LinkitRowDivider()
            SettingsHubRow(
                icon = Icons.Rounded.Info,
                title = "About",
                subtitle = "Version and source code.",
                status = HubStatus("v${state.currentAndroidVersion}", HubTone.NEUTRAL),
                accent = accent
            ) { onOpenDetail(SettingsRoute.ABOUT) }
        }
    }
}

// MARK: - Paired devices hero

/**
 * Both halves of the pairing, side by side, with the link drawn between them — Settings is the
 * screen *about* this pairing, so it leads with the pairing rather than with a list. Deliberately
 * not a copy of Home's card, which is about the Mac alone.
 */
@Composable
private fun PairedDevicesHero(state: LinkitUiState, onClick: () -> Unit) {
    val accent = MaterialTheme.colorScheme.primary
    val connected = state.isConnectedToMac
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(22.dp))
            .background(
                Brush.verticalGradient(
                    listOf(
                        accent.copy(alpha = if (connected) 0.16f else 0.05f),
                        MaterialTheme.colorScheme.surface
                    )
                )
            )
            .border(
                BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                RoundedCornerShape(22.dp)
            )
            .clickable(onClick = onClick)
            .padding(vertical = 18.dp, horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            DeviceColumn(
                modifier = Modifier.width(96.dp),
                label = Build.MODEL ?: "This phone"
            ) {
                PhoneGlyph(accent = accent, connected = connected)
            }
            LinkTrail(
                connected = connected,
                accent = accent,
                modifier = Modifier.weight(1f)
            )
            DeviceColumn(
                modifier = Modifier.width(96.dp),
                label = state.trustedMac?.deviceName ?: "Mac"
            ) {
                MacBookGlyph(accent = accent, connected = connected, width = 62.dp, height = 40.dp)
            }
        }
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically
        ) {
            StatusPulseDot(
                color = if (connected) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.outline,
                animated = connected,
                size = 7
            )
            Text(
                if (connected) "Paired and connected" else "Paired · offline",
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 6.dp)
            )
        }
    }
}

@Composable
private fun DeviceColumn(
    modifier: Modifier,
    label: String,
    glyph: @Composable () -> Unit
) {
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Box(modifier = Modifier.height(44.dp), contentAlignment = Alignment.Center) { glyph() }
        Text(
            label,
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            color = MaterialTheme.colorScheme.onSurface,
            textAlign = TextAlign.Center,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis
        )
    }
}

/**
 * The link between the two devices: packets travelling left→right while connected, a flat dashed
 * line when not. It is the one piece of this screen that is alive, and it says the thing Settings
 * most needs to say at a glance.
 */
@Composable
private fun LinkTrail(connected: Boolean, accent: Color, modifier: Modifier) {
    val phase = if (connected) {
        rememberInfiniteTransition(label = "link-trail").animateFloat(
            initialValue = 0f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = 2200, easing = LinearEasing)
            ),
            label = "phase"
        ).value
    } else 0f
    val idle = MaterialTheme.colorScheme.outline

    Canvas(modifier = modifier.height(44.dp)) {
        val y = size.height / 2f
        if (!connected) {
            drawLine(
                color = idle.copy(alpha = 0.5f),
                start = Offset(0f, y),
                end = Offset(size.width, y),
                strokeWidth = 2f,
                pathEffect = PathEffect.dashPathEffect(floatArrayOf(6f, 10f))
            )
            return@Canvas
        }
        drawLine(
            brush = Brush.horizontalGradient(
                listOf(accent.copy(alpha = 0.15f), accent.copy(alpha = 0.4f), accent.copy(alpha = 0.15f))
            ),
            start = Offset(0f, y),
            end = Offset(size.width, y),
            strokeWidth = 2f
        )
        // Three evenly spaced dots sharing one phase, so the trail reads as continuous flow
        // rather than a single dot looping.
        repeat(3) { index ->
            val progress = (phase + index / 3f) % 1f
            // Fade in and out at the ends so dots emerge from one device and vanish into the other.
            val fade = kotlin.math.sin(progress * Math.PI).toFloat()
            drawCircle(
                color = accent.copy(alpha = fade),
                radius = 3f,
                center = Offset(size.width * progress, y)
            )
        }
    }
}

/** This phone, drawn in the same vector language as ``MacBookGlyph``. */
@Composable
private fun PhoneGlyph(accent: Color, connected: Boolean) {
    val screenTint = if (connected) accent else MaterialTheme.colorScheme.outline
    val body = MaterialTheme.colorScheme.onSurfaceVariant
    Canvas(modifier = Modifier.width(30.dp).height(44.dp)) {
        drawPhone(screenTint = screenTint, bodyTint = body)
    }
}

private fun DrawScope.drawPhone(screenTint: Color, bodyTint: Color) {
    val bezel = size.width * 0.07f
    drawRoundRect(
        color = bodyTint.copy(alpha = 0.55f),
        topLeft = Offset.Zero,
        size = size,
        cornerRadius = CornerRadius(size.width * 0.2f)
    )
    drawRoundRect(
        brush = Brush.linearGradient(
            colors = listOf(screenTint, screenTint.copy(alpha = 0.45f)),
            start = Offset.Zero,
            end = Offset(size.width, size.height)
        ),
        topLeft = Offset(bezel, bezel),
        size = Size(size.width - bezel * 2, size.height - bezel * 2),
        cornerRadius = CornerRadius(size.width * 0.15f)
    )
}

// MARK: - Hub rows

internal enum class HubTone { ON, OFF, ATTENTION, NEUTRAL }

internal data class HubStatus(val label: String, val tone: HubTone)

/** Maps a live feature-health entry onto the compact word shown at the end of its hub row. */
internal fun LinkitUiState.hubStatus(featureId: String): HubStatus {
    val feature = localFeatures.firstOrNull { it.id == featureId }
        ?: return HubStatus("", HubTone.NEUTRAL)
    return when (feature.state) {
        FeatureState.ON -> HubStatus("On", HubTone.ON)
        FeatureState.OFF -> HubStatus("Off", HubTone.OFF)
        FeatureState.ATTENTION -> HubStatus("Needs attention", HubTone.ATTENTION)
        FeatureState.UNSUPPORTED -> HubStatus("Unsupported", HubTone.OFF)
    }
}

internal fun updateStatus(state: LinkitUiState): HubStatus = when {
    state.isCheckingUpdate -> HubStatus("Checking…", HubTone.NEUTRAL)
    state.availableAndroidUpdate != null ->
        HubStatus("v${state.availableAndroidUpdate.versionName} ready", HubTone.ATTENTION)
    else -> HubStatus("Up to date", HubTone.ON)
}

/**
 * A hub category row. Unlike the plain card row it wraps, the trailing slot carries the category's
 * current state, and an `attention` row tints its whole background so a problem is visible while
 * scanning rather than only on close reading.
 */
@Composable
private fun SettingsHubRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    status: HubStatus,
    accent: Color,
    onClick: () -> Unit
) {
    val attention = status.tone == HubTone.ATTENTION
    Box(
        modifier = if (attention) {
            Modifier.background(MaterialTheme.colorScheme.error.copy(alpha = 0.07f))
        } else Modifier
    ) {
        LinkitCardRow(
            icon = icon,
            title = title,
            subtitle = subtitle,
            accent = accent,
            onClick = onClick
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                if (status.label.isNotEmpty()) {
                    if (attention) {
                        Box(
                            modifier = Modifier
                                .size(7.dp)
                                .clip(CircleShape)
                                .background(MaterialTheme.colorScheme.error)
                        )
                    }
                    Text(
                        status.label,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                        color = when (status.tone) {
                            HubTone.ON -> MaterialTheme.colorScheme.tertiary
                            HubTone.ATTENTION -> MaterialTheme.colorScheme.error
                            else -> MaterialTheme.colorScheme.onSurfaceVariant
                        },
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                RowChevron()
            }
        }
    }
}
