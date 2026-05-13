package tech.kalkikgp.linkit

import java.net.Inet6Address
import java.net.InetAddress

object PrivateLanTarget {
    fun validateIp(input: String): Result<String> {
        val trimmed = input.trim()
        if (trimmed.isEmpty()) return Result.failure(IllegalArgumentException("Mac IP is required"))

        parseIpv4(trimmed)?.let { octets ->
            val isPrivate = octets[0] == 10 ||
                (octets[0] == 172 && octets[1] in 16..31) ||
                (octets[0] == 192 && octets[1] == 168) ||
                (octets[0] == 169 && octets[1] == 254)
            return if (isPrivate) {
                Result.success(trimmed)
            } else {
                Result.failure(IllegalArgumentException("Use a private LAN or link-local IP"))
            }
        }

        if (!trimmed.contains(":")) {
            return Result.failure(IllegalArgumentException("Enter a numeric Mac IP, not a hostname"))
        }

        val address = runCatching { InetAddress.getByName(trimmed) }.getOrNull()
        if (address !is Inet6Address) {
            return Result.failure(IllegalArgumentException("Invalid IPv6 address"))
        }

        val bytes = address.address
        val isUniqueLocal = (bytes[0].toInt() and 0xfe) == 0xfc
        val isLinkLocal = address.isLinkLocalAddress
        return if (isUniqueLocal || isLinkLocal) {
            Result.success(trimmed)
        } else {
            Result.failure(IllegalArgumentException("Use a private LAN or link-local IP"))
        }
    }

    fun validatePort(input: String): Result<Int> {
        val port = input.trim().toIntOrNull()
            ?: return Result.failure(IllegalArgumentException("Port must be a number"))
        return if (port in 1..65535) {
            Result.success(port)
        } else {
            Result.failure(IllegalArgumentException("Port must be between 1 and 65535"))
        }
    }

    fun baseUrl(ip: String, port: Int): String {
        val host = if (ip.contains(":")) "[$ip]" else ip
        return "http://$host:$port"
    }

    private fun parseIpv4(input: String): IntArray? {
        val parts = input.split(".")
        if (parts.size != 4) return null
        val octets = IntArray(4)
        for ((index, part) in parts.withIndex()) {
            if (part.isEmpty() || part.length > 3 || part.any { it !in '0'..'9' }) return null
            val value = part.toIntOrNull() ?: return null
            if (value !in 0..255) return null
            octets[index] = value
        }
        return octets
    }
}
