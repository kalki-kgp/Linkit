package tech.kalkikgp.linkit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidUpdatePolicyTest {
    @Test
    fun parsesManifest() {
        val manifest = AndroidUpdatePolicy.parseManifest(
            """
            {
              "platform": "android",
              "versionName": "0.2.0",
              "versionCode": 2,
              "url": "https://example.com/linkit-release.apk",
              "sha256": "${"a".repeat(64)}",
              "releaseNotes": "Small fix"
            }
            """.trimIndent()
        )

        assertEquals("0.2.0", manifest.versionName)
        assertEquals(2, manifest.versionCode)
        assertEquals("Small fix", manifest.releaseNotes)
    }

    @Test
    fun returnsAvailableForHigherVersionCode() {
        val result = AndroidUpdatePolicy.evaluate(manifest(versionCode = 2), currentVersionCode = 1)

        assertTrue(result is AndroidUpdateCheckResult.Available)
    }

    @Test
    fun returnsUpToDateForSameVersionCode() {
        val result = AndroidUpdatePolicy.evaluate(manifest(versionCode = 2), currentVersionCode = 2)

        assertEquals(AndroidUpdateCheckResult.UpToDate, result)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsWrongPlatform() {
        AndroidUpdatePolicy.evaluate(manifest(platform = "macos"), currentVersionCode = 1)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsInsecureUrl() {
        AndroidUpdatePolicy.evaluate(manifest(url = "http://example.com/linkit.apk"), currentVersionCode = 1)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsInvalidChecksum() {
        AndroidUpdatePolicy.evaluate(manifest(sha256 = "nope"), currentVersionCode = 1)
    }

    private fun manifest(
        platform: String = "android",
        versionName: String = "0.2.0",
        versionCode: Long = 2,
        url: String = "https://example.com/linkit-release.apk",
        sha256: String = "a".repeat(64),
        releaseNotes: String? = null
    ): AndroidUpdateManifest {
        return AndroidUpdateManifest(
            platform = platform,
            versionName = versionName,
            versionCode = versionCode,
            url = url,
            sha256 = sha256,
            releaseNotes = releaseNotes
        )
    }
}
