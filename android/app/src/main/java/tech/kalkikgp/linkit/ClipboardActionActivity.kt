package tech.kalkikgp.linkit

import android.app.Activity
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import kotlinx.coroutines.runBlocking

class ClipboardActionActivity : Activity() {
    private var actionType: String? = null
    private var handled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        actionType = intent?.getStringExtra(EXTRA_ACTION_TYPE)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || handled) return
        handled = true
        handleAction()
    }

    private fun handleAction() {
        val store = IdentityStore(applicationContext)
        val mac = store.trustedMac()
        if (mac == null) {
            Toast.makeText(this, "Pair Linkit with your Mac first", Toast.LENGTH_LONG).show()
            finish()
            return
        }
        val text = currentClipboardText()
        if (text.isNullOrBlank()) {
            Toast.makeText(this, "Clipboard is empty", Toast.LENGTH_SHORT).show()
            finish()
            return
        }

        when (actionType) {
            ACTION_OPEN_LINK -> {
                val scheme = runCatching { Uri.parse(text).scheme?.lowercase() }.getOrNull()
                if (scheme != "http" && scheme != "https") {
                    Toast.makeText(this, "Clipboard does not contain an http or https URL", Toast.LENGTH_LONG).show()
                    finish()
                    return
                }
                dispatch(mac, store, "open_url", text, "Opening link on Mac")
            }
            else -> dispatch(mac, store, "clipboard", text, "Clipboard sent to Mac")
        }
    }

    private fun dispatch(mac: TrustedMac, store: IdentityStore, type: String, text: String, successMessage: String) {
        Thread {
            val result = runCatching {
                runBlocking { LinkitClient().sendAction(mac, store, type, text) }
            }
            runOnUiThread {
                result.onSuccess {
                    Toast.makeText(this, successMessage, Toast.LENGTH_SHORT).show()
                }.onFailure { error ->
                    Toast.makeText(this, "Handoff failed: ${error.message}", Toast.LENGTH_LONG).show()
                }
                finish()
            }
        }.start()
    }

    private fun currentClipboardText(): String? {
        val clipboard = getSystemService(ClipboardManager::class.java)
        val item = clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0) ?: return null
        return item.coerceToText(this)?.toString()?.trim()
    }

    companion object {
        const val EXTRA_ACTION_TYPE = "tech.kalkikgp.linkit.extra.ACTION_TYPE"
        const val ACTION_SEND_CLIPBOARD = "send_clipboard"
        const val ACTION_OPEN_LINK = "open_link"

        fun intent(context: android.content.Context, actionType: String): Intent {
            return Intent(context, ClipboardActionActivity::class.java).apply {
                putExtra(EXTRA_ACTION_TYPE, actionType)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_HISTORY)
            }
        }
    }
}
