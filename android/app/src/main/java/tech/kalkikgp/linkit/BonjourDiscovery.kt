package tech.kalkikgp.linkit

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo

data class DiscoveredMac(
    val name: String,
    val ip: String,
    val port: Int
)

class BonjourDiscovery(context: Context) {
    private val manager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var listener: NsdManager.DiscoveryListener? = null

    fun start(
        onFound: (DiscoveredMac) -> Unit,
        onError: (String) -> Unit,
        nameFilter: String? = null
    ) {
        stop()
        val discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                if (serviceInfo.serviceType != "_linkit._tcp.") return
                if (nameFilter != null && !serviceInfo.serviceName.matchesMacName(nameFilter)) return
                manager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = Unit

                    override fun onServiceResolved(resolved: NsdServiceInfo) {
                        if (nameFilter != null && !resolved.serviceName.matchesMacName(nameFilter)) return
                        val ip = resolved.host?.hostAddress ?: return
                        onFound(DiscoveredMac(resolved.serviceName, ip, resolved.port))
                        stop()
                    }
                })
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                onError("Discovery failed: $errorCode")
                stop()
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                stop()
            }
        }
        listener = discoveryListener
        manager.discoverServices("_linkit._tcp.", NsdManager.PROTOCOL_DNS_SD, discoveryListener)
    }

    fun stop() {
        listener?.let {
            runCatching { manager.stopServiceDiscovery(it) }
        }
        listener = null
    }
}

private fun String.matchesMacName(deviceName: String): Boolean {
    val needle = deviceName.trim().lowercase()
    if (needle.isEmpty()) return false
    val hay = this.trim().lowercase()
    return hay == needle || hay == "linkit $needle" || hay.endsWith(" $needle") || hay.contains(needle)
}
