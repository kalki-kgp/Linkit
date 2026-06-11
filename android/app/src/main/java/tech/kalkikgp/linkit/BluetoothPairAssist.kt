package tech.kalkikgp.linkit

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import org.json.JSONObject

data class BluetoothPermissionStatus(
    val canConnect: Boolean
) {
    val summary: String
        get() = if (canConnect) {
            "Bluetooth ready for call audio"
        } else {
            "Bluetooth permission needed for call audio on Mac"
        }
}

object BluetoothPermissions {
    val requested: Array<String>
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            arrayOf(Manifest.permission.BLUETOOTH, Manifest.permission.BLUETOOTH_ADMIN)
        }

    fun status(context: Context): BluetoothPermissionStatus {
        fun granted(permission: String): Boolean =
            ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

        val canConnect = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            granted(Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            granted(Manifest.permission.BLUETOOTH) && granted(Manifest.permission.BLUETOOTH_ADMIN)
        }
        return BluetoothPermissionStatus(canConnect = canConnect)
    }
}

data class CallAudioStatus(
    val canConnect: Boolean,
    val macBluetoothAddress: String?,
    val isPairedWithMac: Boolean,
    val isBonding: Boolean
) {
    val summary: String
        get() = when {
            !canConnect -> "Grant Bluetooth to route call audio to your Mac"
            macBluetoothAddress.isNullOrBlank() -> "Mac Bluetooth address unavailable"
            isPairedWithMac -> "Call audio on Mac is ready"
            isBonding -> "Confirm pairing on your phone..."
            else -> "Pair once to hear calls on your Mac speakers"
        }

    val isReady: Boolean
        get() = canConnect && !macBluetoothAddress.isNullOrBlank() && isPairedWithMac
}

object BluetoothAddressPolicy {
    private val pattern = Regex("""^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$""")

    fun normalized(input: String): String? {
        val trimmed = input.trim().uppercase()
        if (pattern.matches(trimmed)) return trimmed
        val compact = trimmed.filter { it.isDigit() || it in 'A'..'F' }
        if (compact.length != 12) return null
        return compact.chunked(2).joinToString(":")
    }
}

class BluetoothPairAssist(private val context: Context) {
    private var bondReceiver: BroadcastReceiver? = null

    fun handleAction(text: String): JSONObject {
        val address = runCatching {
            val json = JSONObject(text)
            BluetoothAddressPolicy.normalized(json.getString("address"))
        }.getOrNull()
            ?: throw DropHttpFailure(400, "invalid_bt_address", "Bluetooth address is invalid")

        if (!BluetoothPermissions.status(context).canConnect) {
            throw DropHttpFailure(403, "missing_bluetooth_permission", "Grant Bluetooth permission on Android first")
        }

        val adapter = bluetoothAdapter()
            ?: throw DropHttpFailure(503, "bluetooth_unavailable", "Bluetooth is not available on this phone")

        if (!adapter.isEnabled) {
            throw DropHttpFailure(503, "bluetooth_disabled", "Turn on Bluetooth on your phone first")
        }

        val device = adapter.getRemoteDevice(address)
        // The phone's user-visible Bluetooth name lets the Mac pick this exact
        // device out of its paired list (addresses are unreliable cross-side).
        val bluetoothName = runCatching { adapter.name }.getOrNull().orEmpty()
        return when (device.bondState) {
            BluetoothDevice.BOND_BONDED -> JSONObject()
                .put("status", "ok")
                .put("type", "bt_pair")
                .put("mode", "already_paired")
                .put("bluetoothName", bluetoothName)
            BluetoothDevice.BOND_BONDING -> JSONObject()
                .put("status", "ok")
                .put("type", "bt_pair")
                .put("mode", "bonding")
                .put("bluetoothName", bluetoothName)
            else -> {
                registerBondReceiver()
                val started = runCatching { device.createBond() }.getOrDefault(false)
                if (!started) {
                    throw DropHttpFailure(500, "bond_failed", "Could not start Bluetooth pairing")
                }
                DebugTelemetry.recordEvent("bluetooth", "bonding with $address")
                JSONObject()
                    .put("status", "ok")
                    .put("type", "bt_pair")
                    .put("mode", "bonding")
                    .put("bluetoothName", bluetoothName)
            }
        }
    }

    fun bondWithMac(macBluetoothAddress: String): JSONObject {
        return handleAction(JSONObject().put("address", macBluetoothAddress).toString())
    }

    fun callAudioStatus(macBluetoothAddress: String?): CallAudioStatus {
        val permission = BluetoothPermissions.status(context)
        val normalizedMac = macBluetoothAddress?.let(BluetoothAddressPolicy::normalized)
        val adapter = bluetoothAdapter()
        val paired = normalizedMac != null && adapter?.bondedDevices?.any {
            BluetoothAddressPolicy.normalized(it.address) == normalizedMac
        } == true
        val bonding = normalizedMac != null && adapter?.bondedDevices?.none {
            BluetoothAddressPolicy.normalized(it.address) == normalizedMac
        } == true && adapter.getRemoteDevice(normalizedMac).bondState == BluetoothDevice.BOND_BONDING
        return CallAudioStatus(
            canConnect = permission.canConnect,
            macBluetoothAddress = normalizedMac,
            isPairedWithMac = paired,
            isBonding = bonding
        )
    }

    fun stop() {
        bondReceiver?.let { receiver ->
            runCatching { context.unregisterReceiver(receiver) }
        }
        bondReceiver = null
    }

    private fun bluetoothAdapter(): BluetoothAdapter? {
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        return manager?.adapter ?: BluetoothAdapter.getDefaultAdapter()
    }

    private fun registerBondReceiver() {
        if (bondReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(receiverContext: Context?, intent: Intent?) {
                if (intent?.action != BluetoothDevice.ACTION_BOND_STATE_CHANGED) return
                val device = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                    ?: return
                when (intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.BOND_NONE)) {
                    BluetoothDevice.BOND_BONDED ->
                        DebugTelemetry.recordEvent("bluetooth", "bonded with ${device.address}")
                    BluetoothDevice.BOND_NONE ->
                        DebugTelemetry.recordEvent("bluetooth", "bond cleared for ${device.address}")
                }
            }
        }
        val filter = IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
        bondReceiver = receiver
    }
}
