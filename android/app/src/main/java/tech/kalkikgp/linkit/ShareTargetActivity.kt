package tech.kalkikgp.linkit

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.widget.Toast
import java.io.File
import java.io.FileOutputStream

class ShareTargetActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val uris = extractUris(intent)
        if (uris.isEmpty()) {
            Toast.makeText(this, "Nothing to share", Toast.LENGTH_SHORT).show()
            finish()
            return
        }
        if (IdentityStore(applicationContext).trustedMac() == null) {
            Toast.makeText(this, "Pair Linkit with your Mac first", Toast.LENGTH_LONG).show()
            startActivity(Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            })
            finish()
            return
        }

        Toast.makeText(this, "Preparing Linkit send", Toast.LENGTH_SHORT).show()
        Thread {
            val cached = runCatching { cacheSharedUris(uris) }
            runOnUiThread {
                cached.onSuccess { files ->
                    LinkitSendService.enqueueCached(this, files)
                    Toast.makeText(this, "Sending via Linkit", Toast.LENGTH_SHORT).show()
                }.onFailure { error ->
                    Toast.makeText(this, "Could not read shared item: ${error.message}", Toast.LENGTH_LONG).show()
                }
                finish()
            }
        }.start()
    }

    private fun extractUris(intent: Intent?): List<Uri> {
        if (intent == null) return emptyList()
        return when (intent.action) {
            Intent.ACTION_SEND -> {
                val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
                listOfNotNull(uri)
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
                }
            }
            else -> emptyList()
        }
    }

    private fun cacheSharedUris(uris: List<Uri>): List<File> {
        val dir = File(cacheDir, "linkit-shares").apply { mkdirs() }
        return uris.mapIndexed { index, uri ->
            val name = sanitizeCacheName(displayName(uri) ?: uri.lastPathSegment ?: "shared-$index.bin")
            val file = uniqueFile(dir, "${System.currentTimeMillis()}-$index-$name")
            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(file).use { output ->
                    input.copyTo(output, 1024 * 1024)
                }
            } ?: throw IllegalArgumentException("Could not open $name")
            file
        }
    }

    private fun displayName(uri: Uri): String? {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0 && !cursor.isNull(index)) return cursor.getString(index)
            }
        }
        return null
    }

    private fun sanitizeCacheName(raw: String): String {
        return raw
            .replace("/", "_")
            .replace("\\", "_")
            .trim()
            .trimStart('.')
            .ifBlank { "shared.bin" }
            .take(160)
    }

    private fun uniqueFile(dir: File, name: String): File {
        val base = name.substringBeforeLast('.', name)
        val ext = name.substringAfterLast('.', "").takeIf { it.isNotBlank() }?.let { ".$it" }.orEmpty()
        for (attempt in 0..9999) {
            val candidate = if (attempt == 0) File(dir, name) else File(dir, "$base-$attempt$ext")
            if (!candidate.exists()) return candidate
        }
        throw IllegalStateException("Could not allocate cache file")
    }
}
