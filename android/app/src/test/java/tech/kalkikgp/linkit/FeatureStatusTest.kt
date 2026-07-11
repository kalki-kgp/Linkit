package tech.kalkikgp.linkit

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FeatureStatusTest {
    @Test
    fun jsonRoundTripPreservesEveryField() {
        val features = listOf(
            FeatureStatus("notification_mirror", "Notification mirroring", FeatureState.ATTENTION, "not receiving"),
            FeatureStatus("clipboard_sync", "Clipboard sync", FeatureState.ON, "on"),
            FeatureStatus("phone_control", "Phone controls", FeatureState.OFF, "off"),
            FeatureStatus("battery_exemption", "Stay connected", FeatureState.UNSUPPORTED, "n/a")
        )
        val parsed = featureStatusesFromJson(features.toJsonArray())
        assertEquals(features, parsed)
    }

    @Test
    fun stateDecodesFromWireStringUsedByMac() {
        // Matches the Swift FeatureState rawValues so both apps read the same snapshot.
        assertEquals(FeatureState.ON, FeatureState.fromWire("on"))
        assertEquals(FeatureState.OFF, FeatureState.fromWire("off"))
        assertEquals(FeatureState.ATTENTION, FeatureState.fromWire("attention"))
        assertEquals(FeatureState.UNSUPPORTED, FeatureState.fromWire("unsupported"))
    }

    @Test
    fun unknownOrMissingStateDefaultsToOff() {
        assertEquals(FeatureState.OFF, FeatureState.fromWire("garbage"))
        assertEquals(FeatureState.OFF, FeatureState.fromWire(null))
    }

    @Test
    fun emptyOrNullArrayParsesToEmptyList() {
        assertTrue(featureStatusesFromJson(null).isEmpty())
        assertTrue(featureStatusesFromJson(JSONArray()).isEmpty())
    }

    @Test
    fun wireValuesMatchAcrossFeatureStates() {
        assertEquals("on", FeatureState.ON.wire)
        assertEquals("off", FeatureState.OFF.wire)
        assertEquals("attention", FeatureState.ATTENTION.wire)
        assertEquals("unsupported", FeatureState.UNSUPPORTED.wire)
    }
}
