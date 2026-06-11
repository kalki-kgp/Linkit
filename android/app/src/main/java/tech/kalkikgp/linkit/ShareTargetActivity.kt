package tech.kalkikgp.linkit

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import kotlinx.coroutines.runBlocking

class ShareTargetActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val uris = extractUris(intent)
        if (IdentityStore(applicationContext).trustedMac() == null) {
            Toast.makeText(this, "Pair Linkit with your Mac first", Toast.LENGTH_LONG).show()
            startActivity(Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            })
            finish()
            return
        }
        val sharedText = extractText(intent)
        if (uris.isEmpty() && sharedText.isNullOrBlank()) {
            Toast.makeText(this, "Nothing to share", Toast.LENGTH_SHORT).show()
            finish()
            return
        }

        if (uris.isEmpty() && !sharedText.isNullOrBlank()) {
            sendTextHandoff(sharedText)
            return
        }

        runCatching { LinkitSendService.enqueue(this, uris) }
            .onSuccess { Toast.makeText(this, "Sending via Linkit", Toast.LENGTH_SHORT).show() }
            .onFailure { error ->
                Toast.makeText(this, "Could not start Linkit send: ${error.message}", Toast.LENGTH_LONG).show()
            }
        finish()
    }

    private fun sendTextHandoff(text: String) {
        Toast.makeText(this, "Sending via Linkit", Toast.LENGTH_SHORT).show()
        Thread {
            val result = runCatching {
                val store = IdentityStore(applicationContext)
                val mac = store.trustedMac() ?: error("Pair Linkit with your Mac first")
                val type = if (isWebUrl(text)) "open_url" else "text"
                runBlocking { LinkitClient().sendAction(mac, store, type, text.trim()) }
                type
            }
            runOnUiThread {
                result.onSuccess { type ->
                    Toast.makeText(
                        this,
                        if (type == "open_url") "Opening link on Mac" else "Sent text to Mac",
                        Toast.LENGTH_SHORT
                    ).show()
                }.onFailure { error ->
                    Toast.makeText(this, "Could not hand off text: ${error.message}", Toast.LENGTH_LONG).show()
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

    private fun extractText(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_SEND || intent.type?.startsWith("text/") != true) return null
        return intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()
    }

    private fun isWebUrl(text: String): Boolean {
        val trimmed = text.trim()
        return trimmed.startsWith("http://", ignoreCase = true) || trimmed.startsWith("https://", ignoreCase = true)
    }
}
