package tech.kalkikgp.linkit

import org.junit.Assert.assertEquals
import org.junit.Test
import java.net.URLEncoder

class PairingPayloadParserTest {
    @Test
    fun identityProofCanonicalStringMatchesProtocol() {
        assertEquals(
            "LINKIT_IDENTITY_PROOF\nmac-device\npublic-key\nchallenge",
            LinkitIdentityProof.canonicalString(
                deviceId = "mac-device",
                publicKey = "public-key",
                challenge = "challenge"
            )
        )
    }

    @Test
    fun parsesJsonPayloadWithExpiry() {
        val payload = PairingPayloadParser.parse(
            """
            {
              "v": 1,
              "deviceId": "mac-device",
              "deviceName": "Krishna Mac",
              "publicKey": "abc",
              "ip": "10.0.0.5",
              "port": 52718,
              "pairingToken": "token",
              "pairingChallenge": "challenge",
              "pairingSecret": "dGVzdC1zZWNyZXQ=",
              "pairingTokenExpiresAt": "2026-05-16T02:30:00Z"
            }
            """.trimIndent()
        )

        assertEquals("mac-device", payload.deviceId)
        assertEquals("10.0.0.5", payload.ip)
        assertEquals(52718, payload.port)
        assertEquals("2026-05-16T02:30:00Z", payload.pairingTokenExpiresAt)
        assertEquals("challenge", payload.pairingChallenge)
        assertEquals("dGVzdC1zZWNyZXQ=", payload.pairingSecret)
    }

    @Test
    fun parsesUrlEncodedPayload() {
        val json = """{"v":1,"deviceId":"mac","deviceName":"Linkit Mac","publicKey":"pk","ip":"192.168.1.7","port":52718,"pairingToken":"tok","pairingChallenge":"challenge","pairingSecret":"dGVzdC1zZWNyZXQ="}"""
        val encoded = URLEncoder.encode(json, Charsets.UTF_8.name())
        val payload = PairingPayloadParser.parse("linkit://pair?payload=$encoded")

        assertEquals("mac", payload.deviceId)
        assertEquals("192.168.1.7", payload.ip)
        assertEquals("tok", payload.pairingToken)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsUnsupportedVersion() {
        PairingPayloadParser.parse("""{"v":2}""")
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsMissingRequiredField() {
        PairingPayloadParser.parse("""{"v":1,"deviceId":"mac"}""")
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsMalformedJson() {
        PairingPayloadParser.parse("""{"v":1,"deviceId":""")
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsOversizedPayload() {
        PairingPayloadParser.parse("a".repeat(16 * 1024 + 1))
    }
}
