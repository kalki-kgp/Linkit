package tech.kalkikgp.linkit

import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.util.Size
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.InsertDriveFile
import androidx.compose.material.icons.rounded.ArrowDownward
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/**
 * Activity as a two-sided timeline: a spine down the middle with received drops branching left
 * and sends branching right, so the direction of every transfer is legible at a glance instead
 * of having to read an arrow on a uniform list row.
 */
@Composable
fun ActivityTimeline(
    entries: List<TransferHistoryEntry>,
    state: LinkitUiState,
    onClear: () -> Unit,
    onCancel: () -> Unit
) {
    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(
                    "Activity",
                    fontSize = 28.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onBackground
                )
                Text(
                    "Saved to Downloads/Linkit Drop",
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            if (entries.isNotEmpty()) {
                TextButton(onClick = onClear) {
                    Text(
                        "Clear",
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.primary
                    )
                }
            }
        }

        Spacer(modifier = Modifier.height(14.dp))

        if (entries.isEmpty() && !state.isSending) {
            EmptyTimeline()
            return@Column
        }

        // One continuous spine drawn behind every node, so day chips and cards read as beads on
        // a single thread rather than as separate stacked rows.
        Box(modifier = Modifier.fillMaxWidth()) {
            val spineColor = MaterialTheme.colorScheme.outlineVariant
            Canvas(modifier = Modifier.matchParentSize()) {
                val x = size.width / 2f
                drawLine(
                    brush = Brush.verticalGradient(
                        listOf(
                            spineColor.copy(alpha = 0f),
                            spineColor,
                            spineColor,
                            spineColor.copy(alpha = 0f)
                        )
                    ),
                    start = Offset(x, 0f),
                    end = Offset(x, size.height),
                    strokeWidth = 2f
                )
            }

            Column(modifier = Modifier.fillMaxWidth()) {
                if (state.isSending) {
                    TimelineProgressCard(state = state, onCancel = onCancel)
                }
                var side = 0
                groupByDay(entries).forEach { (label, dayEntries) ->
                    TimelineDayChip(label)
                    dayEntries.forEach { entry ->
                        TimelineEntryRow(entry = entry, alignStart = side % 2 == 0)
                        side += 1
                    }
                }
                Spacer(modifier = Modifier.height(4.dp))
            }
        }
    }
}

@Composable
private fun EmptyTimeline() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.6f))
            .border(
                BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
                RoundedCornerShape(18.dp)
            )
            .padding(vertical = 34.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            "Files and handoffs will appear here.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
private fun TimelineDayChip(label: String) {
    Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        Text(
            label,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier
                .padding(vertical = 10.dp)
                .clip(RoundedCornerShape(50))
                .background(MaterialTheme.colorScheme.surfaceVariant)
                .border(
                    BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                    RoundedCornerShape(50)
                )
                .padding(horizontal = 14.dp, vertical = 5.dp)
        )
    }
}

@Composable
private fun TimelineEntryRow(entry: TransferHistoryEntry, alignStart: Boolean) {
    val isSent = entry.direction == TransferHistoryEntry.DIRECTION_SENT
    val accent = if (isSent) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.tertiary
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // The card takes the larger share: a filename needs the room far more than the empty
        // side does, and the alternation still reads clearly at 5:3.
        if (alignStart) {
            TimelineCard(entry = entry, accent = accent, modifier = Modifier.weight(1.25f))
            TimelineNode(accent)
            Spacer(modifier = Modifier.weight(0.75f))
        } else {
            Spacer(modifier = Modifier.weight(0.75f))
            TimelineNode(accent)
            TimelineCard(entry = entry, accent = accent, modifier = Modifier.weight(1.25f))
        }
    }
}

/** The bead on the spine: a solid dot inside its own soft halo, tinted by direction. */
@Composable
private fun TimelineNode(accent: Color) {
    Box(
        modifier = Modifier.size(22.dp),
        contentAlignment = Alignment.Center
    ) {
        Box(
            modifier = Modifier
                .size(20.dp)
                .clip(CircleShape)
                .background(accent.copy(alpha = 0.16f))
        )
        Box(
            modifier = Modifier
                .size(9.dp)
                .clip(CircleShape)
                .background(accent)
        )
    }
}

@Composable
private fun TimelineCard(
    entry: TransferHistoryEntry,
    accent: Color,
    modifier: Modifier
) {
    val isSent = entry.direction == TransferHistoryEntry.DIRECTION_SENT
    val context = LocalContext.current
    val openableUri = entry.contentUri?.takeIf {
        entry.direction == TransferHistoryEntry.DIRECTION_RECEIVED &&
            entry.status == TransferHistoryEntry.STATUS_COMPLETE
    }
    val thumbnail = rememberThumbnail(openableUri)

    Column(
        modifier = modifier
            .clip(RoundedCornerShape(14.dp))
            .background(
                Brush.horizontalGradient(
                    listOf(
                        MaterialTheme.colorScheme.surface,
                        accent.copy(alpha = 0.10f)
                    )
                )
            )
            .border(
                BorderStroke(1.dp, accent.copy(alpha = 0.28f)),
                RoundedCornerShape(14.dp)
            )
            .let { base ->
                if (openableUri != null) base.clickable { openTransferFile(context, openableUri) } else base
            }
            .padding(horizontal = 11.dp, vertical = 9.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(5.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = if (isSent) Icons.Rounded.ArrowUpward else Icons.Rounded.ArrowDownward,
                contentDescription = null,
                tint = accent,
                modifier = Modifier.size(14.dp)
            )
            Text(
                if (isSent) "Sent" else "Received",
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Spacer(modifier = Modifier.weight(1f))
            TimelineStatusLabel(entry.status, accent)
        }

        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            TimelineThumbnail(thumbnail = thumbnail, accent = accent)
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp)
            ) {
                Text(
                    entry.filename,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text(
                        formatBytes(entry.size),
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1
                    )
                    Text(
                        clockTime(entry.completedAt),
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1
                    )
                }
            }
        }
    }
}

@Composable
private fun TimelineStatusLabel(status: String, accent: Color) {
    when (status) {
        // A completed transfer is the norm; only deviations earn a word here.
        TransferHistoryEntry.STATUS_COMPLETE -> Unit
        TransferHistoryEntry.STATUS_FAILED -> Text(
            "Failed",
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            color = MaterialTheme.colorScheme.error
        )
        else -> Text(
            status.replaceFirstChar { it.uppercase() },
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            color = accent
        )
    }
}

@Composable
private fun TimelineThumbnail(thumbnail: ImageBitmap?, accent: Color) {
    Box(
        modifier = Modifier
            .size(34.dp)
            .clip(RoundedCornerShape(9.dp))
            .background(accent.copy(alpha = 0.14f)),
        contentAlignment = Alignment.Center
    ) {
        if (thumbnail != null) {
            Image(
                bitmap = thumbnail,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize()
            )
        } else {
            Icon(
                imageVector = Icons.AutoMirrored.Rounded.InsertDriveFile,
                contentDescription = null,
                tint = accent,
                modifier = Modifier.size(16.dp)
            )
        }
    }
}

/** The live transfer, shown inline at the head of the timeline where the next entry will land. */
@Composable
private fun TimelineProgressCard(state: LinkitUiState, onCancel: () -> Unit) {
    val accent = MaterialTheme.colorScheme.primary
    val fraction = if (state.totalBytes > 0) {
        (state.bytesSent.toFloat() / state.totalBytes).coerceIn(0f, 1f)
    } else 0f
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = 6.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surface)
            .border(BorderStroke(1.dp, accent.copy(alpha = 0.35f)), RoundedCornerShape(16.dp))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(9.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconTile(icon = Icons.Rounded.ArrowUpward, accent = accent, size = 30)
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    state.currentFileName ?: "Transfer in progress",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Text(
                    "${formatBytes(state.bytesSent)} / ${formatBytes(state.totalBytes)}" +
                        (state.etaSeconds?.let { "  ·  ${formatEta(it)} left" } ?: ""),
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            TextButton(onClick = onCancel) {
                Text("Cancel", fontSize = 13.sp, color = MaterialTheme.colorScheme.error)
            }
        }
        LinearProgressIndicator(
            progress = { fraction },
            modifier = Modifier
                .fillMaxWidth()
                .height(5.dp)
                .clip(RoundedCornerShape(50)),
            color = accent,
            trackColor = MaterialTheme.colorScheme.surfaceVariant,
            gapSize = 0.dp,
            drawStopIndicator = {}
        )
    }
}

// MARK: - Data helpers

/**
 * Groups newest-first entries under "Today" / "Yesterday" / a date, preserving order. The store
 * already returns newest-first, so a plain fold keeps the timeline reading top-down as most
 * recent first without a second sort.
 */
internal fun groupByDay(
    entries: List<TransferHistoryEntry>,
    now: Long = System.currentTimeMillis()
): List<Pair<String, List<TransferHistoryEntry>>> {
    if (entries.isEmpty()) return emptyList()
    val today = startOfDay(now)
    val yesterday = today - 86_400_000L
    val grouped = LinkedHashMap<String, MutableList<TransferHistoryEntry>>()
    entries.forEach { entry ->
        val dayStart = startOfDay(entry.completedAt)
        val label = when {
            dayStart >= today -> "Today"
            dayStart >= yesterday -> "Yesterday"
            else -> SimpleDateFormat("MMM d", Locale.getDefault()).format(Date(entry.completedAt))
        }
        grouped.getOrPut(label) { mutableListOf() }.add(entry)
    }
    return grouped.map { it.key to it.value }
}

private fun startOfDay(epochMillis: Long): Long {
    val calendar = Calendar.getInstance()
    calendar.timeInMillis = epochMillis
    calendar.set(Calendar.HOUR_OF_DAY, 0)
    calendar.set(Calendar.MINUTE, 0)
    calendar.set(Calendar.SECOND, 0)
    calendar.set(Calendar.MILLISECOND, 0)
    return calendar.timeInMillis
}

private fun clockTime(epochMillis: Long): String =
    SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(epochMillis))

/**
 * Best-effort thumbnail for a received file. Everything here is allowed to fail — an unreadable
 * URI, a non-image, a revoked permission — and the card falls back to a generic file glyph.
 */
@Composable
private fun rememberThumbnail(uriString: String?): ImageBitmap? {
    val context = LocalContext.current
    var bitmap by remember(uriString) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(uriString) {
        if (uriString == null) return@LaunchedEffect
        bitmap = withContext(Dispatchers.IO) { loadThumbnail(context, uriString) }
    }
    return bitmap
}

private fun loadThumbnail(context: Context, uriString: String): ImageBitmap? = runCatching {
    val uri = Uri.parse(uriString)
    val mime = context.contentResolver.getType(uri).orEmpty()
    if (!mime.startsWith("image/") && !mime.startsWith("video/")) return null

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        return context.contentResolver
            .loadThumbnail(uri, Size(THUMBNAIL_PX, THUMBNAIL_PX), null)
            .asImageBitmap()
    }
    // Pre-Q has no thumbnail API for arbitrary content URIs: measure first, then decode
    // subsampled so a 12 MP photo never becomes a full-size bitmap on the heap.
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
    val largest = maxOf(bounds.outWidth, bounds.outHeight)
    if (largest <= 0) return null
    val options = BitmapFactory.Options().apply {
        inSampleSize = maxOf(1, Integer.highestOneBit(largest / THUMBNAIL_PX))
    }
    context.contentResolver.openInputStream(uri)?.use {
        BitmapFactory.decodeStream(it, null, options)?.asImageBitmap()
    }
}.getOrNull()

private const val THUMBNAIL_PX = 128

/** Hands a received file to whichever app claims its type; a no-op toast when nothing does. */
internal fun openTransferFile(context: Context, uriString: String) {
    val uri = runCatching { Uri.parse(uriString) }.getOrNull() ?: return
    val mimeType = context.contentResolver.getType(uri) ?: "*/*"
    val intent = android.content.Intent(android.content.Intent.ACTION_VIEW).apply {
        setDataAndType(uri, mimeType)
        addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
        addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    val opened = runCatching { context.startActivity(intent); true }.getOrDefault(false)
    if (!opened) {
        android.widget.Toast.makeText(context, "No app can open this file", android.widget.Toast.LENGTH_SHORT).show()
    }
}
