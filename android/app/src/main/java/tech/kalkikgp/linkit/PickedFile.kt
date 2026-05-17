package tech.kalkikgp.linkit

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns

data class PickedFile(
    val uri: Uri,
    val name: String,
    val size: Long,
    val mimeType: String
)

fun ContentResolver.loadPickedFile(uri: Uri): PickedFile {
    var name: String? = null
    var size: Long? = null

    query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
        if (cursor.moveToFirst()) {
            val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
            if (nameIndex >= 0) name = cursor.getString(nameIndex)
            if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) size = cursor.getLong(sizeIndex)
        }
    }

    val displayName = name?.takeIf { it.isNotBlank() } ?: uri.lastPathSegment ?: "upload.bin"
    val byteSize = size?.takeIf { it >= 0 }
        ?: streamSize(uri)
    val mime = getType(uri) ?: "application/octet-stream"

    return PickedFile(uri = uri, name = displayName, size = byteSize, mimeType = mime)
}

private fun ContentResolver.streamSize(uri: Uri): Long {
    var total = 0L
    val buffer = ByteArray(1024 * 1024)
    openInputStream(uri)?.use { input ->
        while (true) {
            val read = input.read(buffer)
            if (read == -1) break
            total += read.toLong()
        }
    } ?: throw IllegalArgumentException("Could not open this content URI")
    return total
}
