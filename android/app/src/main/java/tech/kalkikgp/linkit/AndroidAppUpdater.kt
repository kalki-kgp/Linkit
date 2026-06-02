package tech.kalkikgp.linkit

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.security.MessageDigest

data class AndroidUpdateManifest(
    val platform: String,
    val versionName: String,
    val versionCode: Long,
    val url: String,
    val sha256: String,
    val releaseNotes: String?
) {
    val normalizedChecksum: String = sha256.trim().lowercase()
}

data class AndroidAvailableUpdate(
    val manifest: AndroidUpdateManifest
) {
    val versionName: String = manifest.versionName
    val versionCode: Long = manifest.versionCode
}

sealed class AndroidUpdateCheckResult {
    data object UpToDate : AndroidUpdateCheckResult()
    data class Available(val update: AndroidAvailableUpdate) : AndroidUpdateCheckResult()
}

object AndroidUpdatePolicy {
    fun parseManifest(body: String): AndroidUpdateManifest {
        val json = JSONObject(body)
        return AndroidUpdateManifest(
            platform = json.getString("platform"),
            versionName = json.getString("versionName"),
            versionCode = json.getLong("versionCode"),
            url = json.getString("url"),
            sha256 = json.getString("sha256"),
            releaseNotes = json.optString("releaseNotes").takeIf { it.isNotBlank() }
        )
    }

    fun evaluate(manifest: AndroidUpdateManifest, currentVersionCode: Long): AndroidUpdateCheckResult {
        validateManifest(manifest)
        return if (manifest.versionCode > currentVersionCode) {
            AndroidUpdateCheckResult.Available(AndroidAvailableUpdate(manifest))
        } else {
            AndroidUpdateCheckResult.UpToDate
        }
    }

    private fun validateManifest(manifest: AndroidUpdateManifest) {
        require(manifest.platform.lowercase() == "android") { "Update is for ${manifest.platform}, not Android." }
        require(manifest.url.startsWith("https://")) { "Update URL must use HTTPS." }
        require(Regex("^[0-9a-f]{64}$").matches(manifest.normalizedChecksum)) {
            "Update manifest has an invalid SHA-256 checksum."
        }
    }
}

class AndroidAppUpdater(
    private val context: Context,
    private val manifestUrl: String = BuildConfig.LINKIT_ANDROID_UPDATE_MANIFEST_URL,
    private val client: OkHttpClient = OkHttpClient()
) {
    fun checkForUpdates(): AndroidUpdateCheckResult {
        val manifest = fetchManifest()
        return AndroidUpdatePolicy.evaluate(manifest, currentVersionCode())
    }

    fun download(update: AndroidAvailableUpdate): File {
        val apk = File(context.cacheDir, "updates/linkit-${update.versionCode}.apk")
        apk.parentFile?.mkdirs()
        if (apk.exists()) apk.delete()

        val request = Request.Builder().url(update.manifest.url).get().build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw IOException("Update download failed: HTTP ${response.code}")
            }
            val body = response.body ?: throw IOException("Update download was empty")
            apk.outputStream().use { output ->
                body.byteStream().copyTo(output)
            }
        }

        val actual = sha256(apk)
        if (actual != update.manifest.normalizedChecksum) {
            apk.delete()
            throw IOException("APK checksum mismatch. Expected ${update.manifest.normalizedChecksum}, got $actual")
        }
        return apk
    }

    fun install(apk: File) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !context.packageManager.canRequestPackageInstalls()) {
            val intent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:${context.packageName}")
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            throw IOException("Allow installs from Linkit, then tap Install again.")
        }

        val uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            apk
        )
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        context.startActivity(intent)
    }

    fun currentVersionLabel(): String {
        val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
        return "${packageInfo.versionName ?: "0.0.0"} (${currentVersionCode()})"
    }

    private fun fetchManifest(): AndroidUpdateManifest {
        val request = Request.Builder().url(manifestUrl).get().build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw IOException("Update check failed: HTTP ${response.code}")
            }
            val body = response.body?.string() ?: throw IOException("Update manifest was empty")
            return AndroidUpdatePolicy.parseManifest(body)
        }
    }

    private fun currentVersionCode(): Long {
        val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageInfo.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            packageInfo.versionCode.toLong()
        }
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val read = input.read(buffer)
                if (read <= 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}
