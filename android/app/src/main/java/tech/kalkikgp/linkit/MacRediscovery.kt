package tech.kalkikgp.linkit

import android.content.Context
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Recovers the trusted Mac's endpoint after a network change. Pairing trust is bound
 * to keys, not addresses: only ip/port go stale when either device moves networks
 * (e.g. hotspot -> shared Wi-Fi). A rediscovered candidate is accepted only after it
 * proves the paired identity, so a different Mac on the network can never hijack trust.
 */
object MacRediscovery {
    private val mutex = Mutex()

    suspend fun rediscover(
        context: Context,
        identityStore: IdentityStore,
        client: LinkitClient,
        timeoutMillis: Long = 5_000
    ): TrustedMac? = mutex.withLock {
        val mac = identityStore.trustedMac() ?: return@withLock null
        val discovery = BonjourDiscovery(context.applicationContext)
        val found = withTimeoutOrNull(timeoutMillis) {
            suspendCancellableCoroutine<DiscoveredMac?> { cont ->
                discovery.start(
                    onFound = { discovered ->
                        if (cont.isActive) cont.resume(discovered) { discovery.stop() }
                    },
                    onError = {
                        if (cont.isActive) cont.resume(null) { discovery.stop() }
                    },
                    nameFilter = mac.deviceName
                )
                cont.invokeOnCancellation { discovery.stop() }
            }
        }
        discovery.stop()
        if (found == null) {
            DebugTelemetry.recordEvent("reconnect", "rediscovery found no Mac named ${mac.deviceName}")
            return@withLock null
        }
        val candidate = mac.copy(ip = found.ip, port = found.port)
        val verified = runCatching { client.verifyMacEndpoint(candidate) }
            .onFailure { DebugTelemetry.recordEvent("reconnect", "rediscovered candidate rejected: ${it.message}") }
            .isSuccess
        if (!verified) return@withLock null
        identityStore.saveTrustedMac(candidate)
        DebugTelemetry.recordEvent("reconnect", "rediscovered Mac at ${candidate.ip}:${candidate.port}")
        candidate
    }
}
