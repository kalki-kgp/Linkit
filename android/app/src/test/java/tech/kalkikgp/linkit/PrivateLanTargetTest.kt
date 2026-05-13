package tech.kalkikgp.linkit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PrivateLanTargetTest {
    @Test
    fun acceptsPrivateAndLinkLocalIpv4() {
        assertTrue(PrivateLanTarget.validateIp("10.0.2.2").isSuccess)
        assertTrue(PrivateLanTarget.validateIp("172.16.0.4").isSuccess)
        assertTrue(PrivateLanTarget.validateIp("192.168.1.22").isSuccess)
        assertTrue(PrivateLanTarget.validateIp("169.254.10.4").isSuccess)
    }

    @Test
    fun rejectsPublicIpv4AndHostnames() {
        assertTrue(PrivateLanTarget.validateIp("8.8.8.8").isFailure)
        assertTrue(PrivateLanTarget.validateIp("example.com").isFailure)
    }

    @Test
    fun wrapsIpv6HostsInUrl() {
        assertEquals("http://[fe80::1]:52718", PrivateLanTarget.baseUrl("fe80::1", 52718))
    }
}
