package tech.kalkikgp.linkit

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MacSystemStatusTest {
    @Test
    fun `parses a full snapshot from the Mac`() {
        val status = MacSystemStatus.fromJson(
            JSONObject(
                """
                {"batteryPercent":45,"isCharging":true,"powerSource":"ac","minutesToFull":116,
                 "lowPowerMode":true,"networkKind":"wifi","wifiRssi":-62,"wifiQuality":"good",
                 "freeDiskBytes":98087980416,"totalDiskBytes":245107195904,
                 "doNotDisturb":false,"osVersion":"macOS 26.4"}
                """.trimIndent()
            )
        )

        assertEquals(45, status.batteryPercent)
        assertEquals(true, status.isCharging)
        assertTrue(status.isOnAcPower)
        assertEquals(116, status.minutesToFull)
        assertTrue(status.lowPowerMode)
        assertEquals("good", status.wifiQuality)
        assertEquals(-62, status.wifiRssi)
        // Larger than Int.MAX_VALUE, so it has to survive as a Long or the card shows nonsense.
        assertEquals(98_087_980_416L, status.freeDiskBytes)
        assertFalse(status.doNotDisturb)
        assertEquals("macOS 26.4", status.osVersion)
    }

    /**
     * A desktop Mac reports no battery and an Ethernet-only Mac no signal. Absent must stay
     * absent — a 0% battery on the card would be a lie, not a default.
     */
    @Test
    fun `missing readings stay null rather than becoming zero`() {
        val status = MacSystemStatus.fromJson(
            JSONObject("""{"powerSource":"ac","networkKind":"ethernet","osVersion":"macOS 26.4"}""")
        )

        assertNull(status.batteryPercent)
        assertNull(status.isCharging)
        assertNull(status.minutesToFull)
        assertNull(status.wifiRssi)
        assertNull(status.wifiQuality)
        assertNull(status.freeDiskBytes)
        assertTrue(status.isOnAcPower)
        assertFalse(status.lowPowerMode)
        assertFalse(status.doNotDisturb)
    }

    @Test
    fun `explicit nulls are treated as absent`() {
        val status = MacSystemStatus.fromJson(
            JSONObject("""{"batteryPercent":null,"wifiQuality":null,"freeDiskBytes":null}""")
        )

        assertNull(status.batteryPercent)
        assertNull(status.wifiQuality)
        assertNull(status.freeDiskBytes)
    }

    @Test
    fun `battery percent is clamped to a sane range`() {
        assertEquals(
            100,
            MacSystemStatus.fromJson(JSONObject("""{"batteryPercent":140}""")).batteryPercent
        )
        assertEquals(
            0,
            MacSystemStatus.fromJson(JSONObject("""{"batteryPercent":-5}""")).batteryPercent
        )
    }
}
