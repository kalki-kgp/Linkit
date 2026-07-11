package tech.kalkikgp.linkit

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * The accent-color system, mirroring the Mac app's `LinkitAccent` / `Preferences.accentColorHex`.
 * The accent recolors the theme's primary, so cards, toggles, tiles, and status dots all follow it.
 */
object LinkitAccents {
    const val DEFAULT_HEX = "#D16B1F"

    data class Preset(val name: String, val hex: String)

    // Same swatches (and order) the Mac offers in Settings → Appearance.
    val presets: List<Preset> = listOf(
        Preset("Amber", DEFAULT_HEX),
        Preset("Sunset", "#E2562B"),
        Preset("Rose", "#D6336C"),
        Preset("Violet", "#7C4DFF"),
        Preset("Indigo", "#3D5AFE"),
        Preset("Ocean", "#1E88E5"),
        Preset("Teal", "#00897B"),
        Preset("Forest", "#2E7D32"),
        Preset("Graphite", "#5A6370")
    )

    /** Parses `#RRGGBB` (leading `#` optional). Returns null for anything else. */
    fun parse(hex: String): Color? {
        val cleaned = hex.trim().removePrefix("#")
        if (cleaned.length != 6) return null
        val value = cleaned.toLongOrNull(16) ?: return null
        return Color(0xFF000000 or value)
    }

    fun color(hex: String): Color = parse(hex) ?: parse(DEFAULT_HEX)!!

    /** Returns a canonical `#RRGGBB`, falling back to the default when unparseable. */
    fun normalize(hex: String): String {
        val cleaned = hex.trim().removePrefix("#").uppercase()
        return if (cleaned.length == 6 && cleaned.toLongOrNull(16) != null) "#$cleaned" else DEFAULT_HEX
    }

    fun isPreset(hex: String): Boolean {
        val normalized = normalize(hex)
        return presets.any { it.hex.uppercase() == normalized.uppercase() }
    }

    fun nameFor(hex: String): String {
        val normalized = normalize(hex)
        return presets.firstOrNull { it.hex.uppercase() == normalized.uppercase() }?.name
            ?: "Custom ($normalized)"
    }
}

/** Accent gradient used by icon tiles and avatars (top-leading → bottom-trailing). */
fun accentGradient(accent: Color): Brush = Brush.linearGradient(
    colors = listOf(accent, accent.copy(alpha = 0.62f))
)

/**
 * Accent-tinted rounded icon tile at the leading edge of a card row — the app's signature motif,
 * matching the Mac's `IconTile` (a monochrome symbol on an accent gradient).
 */
@Composable
fun IconTile(icon: ImageVector, accent: Color, size: Int = 32) {
    Box(
        modifier = Modifier
            .size(size.dp)
            .clip(RoundedCornerShape((size * 0.28f).dp))
            .background(accentGradient(accent)),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.size((size * 0.56f).dp)
        )
    }
}

/** An uppercase group caption plus a rounded card holding the group's rows (Mac `SettingsGroup`). */
@Composable
fun SettingsGroupCard(label: String, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier = Modifier.fillMaxWidth()) {
        Text(
            label.uppercase(),
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            letterSpacing = 0.9.sp,
            modifier = Modifier.padding(start = 6.dp, bottom = 8.dp)
        )
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(MaterialTheme.colorScheme.surface)
                .border(
                    BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                    RoundedCornerShape(16.dp)
                ),
            content = content
        )
    }
}

/** A card row with an icon tile, title/subtitle, and an arbitrary trailing slot (Mac `CardRow`). */
@Composable
fun LinkitCardRow(
    icon: ImageVector,
    title: String,
    accent: Color,
    subtitle: String? = null,
    enabled: Boolean = true,
    onClick: (() -> Unit)? = null,
    trailing: @Composable () -> Unit = {}
) {
    val base = Modifier.fillMaxWidth()
    val clickable = if (onClick != null && enabled) base.clickable(onClick = onClick) else base
    Row(
        modifier = clickable.padding(horizontal = 14.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        IconTile(icon = icon, accent = accent)
        Column(
            modifier = Modifier.weight(1f).padding(end = 4.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp)
        ) {
            Text(
                title,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = if (enabled) 1f else 0.5f)
            )
            subtitle?.let {
                Text(
                    it,
                    fontSize = 12.sp,
                    lineHeight = 16.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
        trailing()
    }
}

/** A card row whose trailing control is an accent-tinted switch (Mac `ToggleRow`). */
@Composable
fun LinkitToggleRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    accent: Color,
    checked: Boolean,
    enabled: Boolean = true,
    onCheckedChange: (Boolean) -> Unit
) {
    // Tapping anywhere on the row flips the switch — the expected touch affordance on a phone,
    // where the switch alone is a small target.
    LinkitCardRow(
        icon = icon,
        title = title,
        subtitle = subtitle,
        accent = accent,
        enabled = enabled,
        onClick = { onCheckedChange(!checked) }
    ) {
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            enabled = enabled,
            colors = SwitchDefaults.colors(
                checkedTrackColor = accent,
                checkedThumbColor = Color.White
            )
        )
    }
}

/** Divider inset past the icon tile, matching the Mac's `RowDivider`. */
@Composable
fun LinkitRowDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 56.dp)
            .height(1.dp)
            .background(MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.55f))
    )
}

/**
 * A trailing chevron rendered as a real vector glyph (not a text "›"), used on tappable rows.
 */
@Composable
fun RowChevron() {
    Icon(
        imageVector = Icons.Rounded.ChevronRight,
        contentDescription = null,
        tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.55f),
        modifier = Modifier.size(20.dp)
    )
}

/** Big page title + one-line subtitle, echoing the Mac Settings detail header. */
@Composable
fun LinkitLargeHeader(title: String, subtitle: String) {
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(
            title,
            fontSize = 26.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onBackground
        )
        Text(
            subtitle,
            fontSize = 13.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

/** Footer strip echoing the Mac Settings window ("Thanks for using Linkit · vX"). */
@Composable
fun LinkitFooter(version: String, accent: Color) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = Icons.Rounded.FavoriteBorder,
            contentDescription = null,
            tint = accent,
            modifier = Modifier.size(13.dp)
        )
        Text(
            "Thanks for using Linkit",
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Box(modifier = Modifier.weight(1f))
        Text(
            version,
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier
                .clip(RoundedCornerShape(50))
                .background(MaterialTheme.colorScheme.surfaceVariant)
                .padding(horizontal = 9.dp, vertical = 3.dp)
        )
    }
}
