package tech.kalkikgp.linkit

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The hub rows exist to tell the truth about each category without opening it, so the mapping
 * from live feature health to the word on the row is worth pinning down.
 */
class SettingsHubStatusTest {
    @Test
    fun `feature health maps onto the row's status word`() {
        val state = stateWith(
            feature(AndroidFeatureStatus.ID_CLIPBOARD_SYNC, FeatureState.ON),
            feature(AndroidFeatureStatus.ID_NOTIFICATION_MIRROR, FeatureState.ATTENTION),
            feature(AndroidFeatureStatus.ID_PHONE_CONTROL, FeatureState.OFF)
        )

        assertEquals(
            HubStatus("On", HubTone.ON),
            state.hubStatus(AndroidFeatureStatus.ID_CLIPBOARD_SYNC)
        )
        assertEquals(
            HubStatus("Needs attention", HubTone.ATTENTION),
            state.hubStatus(AndroidFeatureStatus.ID_NOTIFICATION_MIRROR)
        )
        assertEquals(
            HubStatus("Off", HubTone.OFF),
            state.hubStatus(AndroidFeatureStatus.ID_PHONE_CONTROL)
        )
    }

    /**
     * Before the first health computation lands the list is empty. A row must stay blank rather
     * than claiming "Off", which would read as a real setting the user had chosen.
     */
    @Test
    fun `an unknown feature produces no status word`() {
        val status = stateWith().hubStatus(AndroidFeatureStatus.ID_CLIPBOARD_SYNC)

        assertEquals("", status.label)
        assertEquals(HubTone.NEUTRAL, status.tone)
    }

    @Test
    fun `a pending update outranks being up to date`() {
        val update = AndroidAvailableUpdate(
            AndroidUpdateManifest(
                platform = "android",
                versionName = "0.9.5",
                versionCode = 22,
                url = "https://example.invalid/linkit.apk",
                sha256 = "0".repeat(64),
                releaseNotes = null
            )
        )

        assertEquals(HubStatus("Up to date", HubTone.ON), updateStatus(stateWith()))
        assertEquals(
            HubStatus("v0.9.5 ready", HubTone.ATTENTION),
            updateStatus(stateWith().copy(availableAndroidUpdate = update))
        )
        assertEquals(
            HubStatus("Checking…", HubTone.NEUTRAL),
            updateStatus(stateWith().copy(isCheckingUpdate = true))
        )
    }

    private fun stateWith(vararg features: FeatureStatus) =
        LinkitUiState(localFeatures = features.toList())

    private fun feature(id: String, state: FeatureState) =
        FeatureStatus(id = id, title = id, state = state, detail = "")
}
