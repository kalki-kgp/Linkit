package tech.kalkikgp.linkit

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

/** How the app should pick light vs. dark. `SYSTEM` follows the OS setting. */
enum class AppearancePreference(val label: String) {
    SYSTEM("System"),
    LIGHT("Light"),
    DARK("Dark")
}

/** Persisted, user-facing preferences mirrored from the Mac Settings surface. */
data class LinkitSettings(
    val appearance: AppearancePreference = AppearancePreference.SYSTEM,
    val clipboardSyncEnabled: Boolean = true
)

/**
 * SharedPreferences-backed settings store exposed as a [StateFlow] so Compose
 * recomposes when a preference changes. Shares the `linkit_prefs` file with the
 * existing one-time prompt flags.
 */
class LinkitPreferences private constructor(context: Context) {
    private val prefs = context.applicationContext
        .getSharedPreferences("linkit_prefs", Context.MODE_PRIVATE)

    private val _settings = MutableStateFlow(read())
    val settings: StateFlow<LinkitSettings> = _settings

    private fun read(): LinkitSettings = LinkitSettings(
        appearance = runCatching {
            AppearancePreference.valueOf(
                prefs.getString(KEY_APPEARANCE, null) ?: AppearancePreference.SYSTEM.name
            )
        }.getOrDefault(AppearancePreference.SYSTEM),
        clipboardSyncEnabled = prefs.getBoolean(KEY_CLIPBOARD_SYNC, true)
    )

    fun setAppearance(value: AppearancePreference) {
        prefs.edit().putString(KEY_APPEARANCE, value.name).apply()
        _settings.update { it.copy(appearance = value) }
    }

    fun setClipboardSyncEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_CLIPBOARD_SYNC, enabled).apply()
        _settings.update { it.copy(clipboardSyncEnabled = enabled) }
    }

    companion object {
        private const val KEY_APPEARANCE = "appearance"
        private const val KEY_CLIPBOARD_SYNC = "clipboard_sync_enabled"

        @Volatile private var instance: LinkitPreferences? = null

        fun get(context: Context): LinkitPreferences =
            instance ?: synchronized(this) {
                instance ?: LinkitPreferences(context).also { instance = it }
            }
    }
}
