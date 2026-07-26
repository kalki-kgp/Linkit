package tech.kalkikgp.linkit

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.SwapVert
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** How much room the floating bar needs at the bottom of a scrolling tab. */
val GlassBarContentPadding = 108.dp

/**
 * The app's map, as a floating glass pill rather than a docked bar.
 *
 * Content scrolls *underneath* it, which is what sells the material: a scrim fades the page out
 * as it reaches the bar, the bar itself is translucent over that fade, and a bright top edge
 * catches the light the way a raised glass surface does. Android has no backdrop-blur primitive
 * for arbitrary composables, so this is layered translucency rather than a true frosted blur —
 * over the fade, the two are hard to tell apart.
 */
@Composable
fun LinkitGlassBottomBar(
    current: TopTab,
    onSelect: (TopTab) -> Unit,
    modifier: Modifier = Modifier
) {
    val background = MaterialTheme.colorScheme.background
    Box(
        modifier = modifier
            .fillMaxWidth()
            // The scrim has to start well above the pill so content dissolves gradually instead
            // of sliding under a hard edge.
            .background(
                Brush.verticalGradient(
                    listOf(
                        background.copy(alpha = 0f),
                        background.copy(alpha = 0.75f),
                        background.copy(alpha = 0.97f)
                    )
                )
            )
            .navigationBarsPadding()
            .padding(horizontal = 18.dp)
            .padding(top = 26.dp, bottom = 10.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .shadow(16.dp, RoundedCornerShape(26.dp), clip = false)
                .clip(RoundedCornerShape(26.dp))
                .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.88f))
                // Sheen: brighter at the top edge, fading out by the middle.
                .background(
                    Brush.verticalGradient(
                        listOf(
                            Color.White.copy(alpha = 0.10f),
                            Color.White.copy(alpha = 0.02f),
                            Color.Transparent
                        )
                    )
                )
                .border(
                    BorderStroke(
                        1.dp,
                        Brush.verticalGradient(
                            listOf(
                                Color.White.copy(alpha = 0.20f),
                                MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f)
                            )
                        )
                    ),
                    RoundedCornerShape(26.dp)
                )
                .padding(vertical = 9.dp),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically
        ) {
            GlassBarItem(Icons.Rounded.Home, "Home", current == TopTab.HOME) { onSelect(TopTab.HOME) }
            GlassBarItem(Icons.Rounded.SwapVert, "Activity", current == TopTab.ACTIVITY) { onSelect(TopTab.ACTIVITY) }
            GlassBarItem(Icons.Rounded.Settings, "Settings", current == TopTab.SETTINGS) { onSelect(TopTab.SETTINGS) }
        }
    }
}

@Composable
private fun GlassBarItem(
    icon: ImageVector,
    label: String,
    selected: Boolean,
    onClick: () -> Unit
) {
    val accent = MaterialTheme.colorScheme.primary
    val tint by animateColorAsState(
        targetValue = if (selected) accent else MaterialTheme.colorScheme.onSurfaceVariant,
        animationSpec = tween(220),
        label = "tab-tint"
    )
    // The selected tab lights up from behind rather than sitting in a filled pill — closer to
    // the glow the Mac's active menu-bar item has, and it keeps the glass looking continuous.
    val glow by animateFloatAsState(
        targetValue = if (selected) 1f else 0f,
        animationSpec = tween(220),
        label = "tab-glow"
    )
    val interactionSource = remember { MutableInteractionSource() }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp),
        modifier = Modifier
            .clip(RoundedCornerShape(18.dp))
            .selectable(
                selected = selected,
                interactionSource = interactionSource,
                indication = androidx.compose.material3.ripple(bounded = false, radius = 40.dp),
                onClick = onClick
            )
            .padding(horizontal = 22.dp, vertical = 4.dp)
    ) {
        Box(contentAlignment = Alignment.Center) {
            if (glow > 0f) {
                Box(
                    modifier = Modifier
                        .size(34.dp)
                        .background(
                            Brush.radialGradient(
                                listOf(
                                    accent.copy(alpha = 0.30f * glow),
                                    accent.copy(alpha = 0f)
                                )
                            )
                        )
                )
            }
            Icon(
                imageVector = icon,
                contentDescription = label,
                tint = tint,
                modifier = Modifier.size(22.dp)
            )
        }
        Text(
            label,
            fontSize = 10.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
            color = tint
        )
    }
}
