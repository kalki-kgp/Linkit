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
    colors = listOf(accent, accent.copy(alpha = 0.6f))
)

/** Accent-tinted rounded glyph tile at the leading edge of a card row (Mac `IconTile`). */
@Composable
fun IconTile(glyph: String, accent: Color, size: Int = 34) {
    Box(
        modifier = Modifier
            .size(size.dp)
            .clip(RoundedCornerShape((size * 0.26f).dp))
            .background(accentGradient(accent)),
        contentAlignment = Alignment.Center
    ) {
        Text(
            glyph,
            color = Color.White,
            fontSize = (size * 0.44f).sp,
            fontWeight = FontWeight.SemiBold
        )
    }
}

/** An uppercase group caption plus a rounded card holding the group's rows (Mac `SettingsGroup`). */
@Composable
fun SettingsGroupCard(label: String, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier = Modifier.fillMaxWidth()) {
        Text(
            label.uppercase(),
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            letterSpacing = 0.8.sp,
            modifier = Modifier.padding(start = 4.dp, bottom = 8.dp)
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
    glyph: String,
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
        IconTile(glyph = glyph, accent = accent)
        Column(
            modifier = Modifier.weight(1f).padding(end = 4.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp)
        ) {
            Text(
                title,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = if (enabled) 1f else 0.5f)
            )
            subtitle?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
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
    glyph: String,
    title: String,
    subtitle: String,
    accent: Color,
    checked: Boolean,
    enabled: Boolean = true,
    onCheckedChange: (Boolean) -> Unit
) {
    LinkitCardRow(glyph = glyph, title = title, subtitle = subtitle, accent = accent, enabled = enabled) {
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
            .background(MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f))
    )
}
