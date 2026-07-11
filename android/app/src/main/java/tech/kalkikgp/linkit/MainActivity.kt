package tech.kalkikgp.linkit

import android.app.Application
import android.content.ClipboardManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.widget.Toast
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import android.text.format.Formatter
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.Call
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.LaptopMac
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.LinkOff
import androidx.compose.material.icons.rounded.LockOpen
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.Palette
import androidx.compose.material.icons.rounded.QrCodeScanner
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material.icons.rounded.UploadFile
import androidx.compose.material.icons.rounded.WarningAmber
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.SwapVert
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.IOException
import java.time.Instant
import java.util.UUID
import kotlin.math.max
import kotlin.math.roundToLong

class MainActivity : ComponentActivity() {
    private val linkitViewModel: LinkitViewModel by viewModels()

    private val notificationPermission = registerForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestPermission()
    ) { /* user choice respected; service still runs */ }

    private val phonePermissions = registerForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestMultiplePermissions()
    ) {
        linkitViewModel.refreshPhoneControlStatus()
        if (IdentityStore(applicationContext).trustedMac() != null) {
            LinkitReceiverService.stop(applicationContext)
            LinkitReceiverService.start(applicationContext)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        DebugTelemetry.install(applicationContext)
        consumeIncomingShareIntent(intent)
        requestNotificationPermissionIfNeeded()
        NotificationAccess.ensureListenerBound(applicationContext)
        if (IdentityStore(applicationContext).trustedMac() != null) {
            LinkitReceiverService.start(applicationContext)
            linkitViewModel.discoverAndReconnect()
            requestBatteryExemptionIfNeeded()
        }
        setContent {
            val settings by linkitViewModel.settings.collectAsStateWithLifecycle()
            val darkTheme = when (settings.appearance) {
                AppearancePreference.SYSTEM -> isSystemInDarkTheme()
                AppearancePreference.LIGHT -> false
                AppearancePreference.DARK -> true
            }
            LinkitTheme(darkTheme = darkTheme, accent = LinkitAccents.color(settings.accentColorHex)) {
                LinkitScreen(
                    viewModel = linkitViewModel,
                    onEnablePhoneControls = { phonePermissions.launch(PhonePermissions.requested) }
                )
            }
        }
    }

    // Asking the OS to exempt Linkit from Doze is what actually keeps the receiver
    // foreground service + Wi-Fi alive while the screen is off, so the Mac doesn't see
    // "not connected". Prompted once; the system shows a single allow/deny dialog.
    private fun requestBatteryExemptionIfNeeded() {
        val powerManager = getSystemService(PowerManager::class.java) ?: return
        if (powerManager.isIgnoringBatteryOptimizations(packageName)) return
        val prefs = getSharedPreferences("linkit_prefs", MODE_PRIVATE)
        if (prefs.getBoolean("battery_exemption_prompted", false)) return
        prefs.edit().putBoolean("battery_exemption_prompted", true).apply()
        runCatching {
            @Suppress("BatteryLife")
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName")
                )
            )
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            val granted = checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
            if (!granted) {
                notificationPermission.launch(android.Manifest.permission.POST_NOTIFICATIONS)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        consumeIncomingShareIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        linkitViewModel.refreshPhoneControlStatus()
        linkitViewModel.refreshFeatureStatus()
        NotificationAccess.ensureListenerBound(applicationContext)
        if (IdentityStore(applicationContext).trustedMac() != null) {
            linkitViewModel.discoverAndReconnect(force = true)
        }
    }

    private fun consumeIncomingShareIntent(intent: Intent?) {
        linkitViewModel.consumeShareIntent(intent)
        if (intent?.action == Intent.ACTION_SEND || intent?.action == Intent.ACTION_SEND_MULTIPLE) {
            setIntent(Intent(this, MainActivity::class.java))
        }
    }
}

data class LinkitUiState(
    val macIp: String = "",
    val port: String = "52718",
    val pairingToken: String = "",
    val pickedFiles: List<PickedFile> = emptyList(),
    val trustedMac: TrustedMac? = null,
    val isConnectedToMac: Boolean = false,
    val isPairing: Boolean = false,
    val isSending: Boolean = false,
    val bytesSent: Long = 0,
    val totalBytes: Long = 0,
    val speedBytesPerSecond: Double = 0.0,
    val etaSeconds: Long? = null,
    val currentFileName: String? = null,
    val androidReceiverStatus: String = "Mac drops starting",
    val lastAndroidDropPath: String? = null,
    val currentAndroidVersion: String = "",
    val availableAndroidUpdate: AndroidAvailableUpdate? = null,
    val isCheckingUpdate: Boolean = false,
    val isInstallingUpdate: Boolean = false,
    val updateStatus: String = "Updates ready",
    val updateError: String? = null,
    val phoneControlStatus: PhoneControlPermissionStatus = PhoneControlPermissionStatus(
        canWatchCalls = false,
        canPlaceDirectCalls = false,
        canControlCalls = false,
        canSeeNumbers = false,
        canResolveContacts = false
    ),
    val status: String = "Ready",
    val error: String? = null,
    val savedPath: String? = null,
    val tokenRejected: Boolean = false,
    val networkHint: String? = null,
    val clipboardSyncEnabled: Boolean = true,
    val localFeatures: List<FeatureStatus> = emptyList(),
    val macFeatures: List<FeatureStatus> = emptyList()
)

class LinkitViewModel(application: Application) : AndroidViewModel(application) {
    private val client = LinkitClient()
    private val identityStore = IdentityStore(application)
    private val discovery = BonjourDiscovery(application)
    private val history = TransferHistoryStore.get(application)
    private val appUpdater = AndroidAppUpdater(application)
    private val preferences = LinkitPreferences.get(application)
    val historyEntries: StateFlow<List<TransferHistoryEntry>> = history.entries
    val settings: StateFlow<LinkitSettings> = preferences.settings

    private val _uiState = MutableStateFlow(
        LinkitUiState(
            trustedMac = identityStore.trustedMac(),
            macIp = identityStore.trustedMac()?.ip.orEmpty(),
            port = identityStore.trustedMac()?.port?.toString() ?: "52718",
            status = if (identityStore.trustedMac() == null) "Pair with Mac" else "Paired, offline",
            androidReceiverStatus = if (identityStore.trustedMac() == null) {
                "Pair with Mac to receive drops"
            } else {
                "Connecting to Mac for drops"
            },
            currentAndroidVersion = appUpdater.currentVersionLabel(),
            phoneControlStatus = PhonePermissions.status(application),
            clipboardSyncEnabled = preferences.settings.value.clipboardSyncEnabled,
            localFeatures = AndroidFeatureStatus.local(application, preferences.settings.value)
        )
    )
    val uiState: StateFlow<LinkitUiState> = _uiState

    private var sendJob: Job? = null
    private var startedAtMillis: Long = 0
    private var clipboardListener: ClipboardManager.OnPrimaryClipChangedListener? = null
    private var lastClipboardText: String? = null
    private var networkRefreshJob: Job? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    init {
        startNetworkMonitor()
        viewModelScope.launch {
            AndroidDropEvents.events.collect { handleDropEvent(it) }
        }
        viewModelScope.launch {
            MacPresence.lastSeenMillis.collect { seenAt ->
                if (seenAt == null) return@collect
                if (_uiState.value.trustedMac == null) return@collect
                // The receiver service may have rediscovered the Mac at a new address
                // while this screen was offline; pick up the persisted endpoint.
                val stored = identityStore.trustedMac() ?: return@collect
                _uiState.update { state ->
                    val endpointChanged = stored != state.trustedMac
                    if (state.isConnectedToMac && state.error == null && !endpointChanged) state
                    else state.copy(
                        trustedMac = stored,
                        macIp = if (endpointChanged) stored.ip else state.macIp,
                        port = if (endpointChanged) stored.port.toString() else state.port,
                        isConnectedToMac = true,
                        status = if (state.isSending || state.isPairing) state.status else "Connected",
                        androidReceiverStatus = "Mac drops enabled",
                        error = null,
                        networkHint = null
                    )
                }
            }
        }
        viewModelScope.launch {
            var offlineTicks = 0
            while (true) {
                delay(10_000)
                val state = _uiState.value
                if (state.isSending || state.isPairing) continue
                val trustedMac = state.trustedMac ?: continue
                if (!state.isConnectedToMac) {
                    // Keep retrying while paired-but-offline: covers the Mac joining
                    // the new network after the phone's connectivity callbacks fired.
                    offlineTicks += 1
                    if (offlineTicks >= 3) {
                        offlineTicks = 0
                        discoverAndReconnect()
                    }
                    continue
                }
                offlineTicks = 0
                val lastSeen = MacPresence.lastSeenMillis.value ?: continue
                val ageMs = System.currentTimeMillis() - lastSeen
                if (ageMs > 45_000) {
                    val stillReachable = withTimeoutOrNull(10_000) {
                        runCatching {
                            client.verifyMacEndpoint(trustedMac)
                            client.registerReceiver(
                                mac = trustedMac,
                                identityStore = identityStore,
                                receivePort = AndroidDropReceiver.PORT,
                                batteryPercent = BatteryStatus.percent(getApplication()),
                                features = localFeatures()
                            )
                        }.isSuccess
                    } == true
                    if (stillReachable) {
                        DebugTelemetry.recordEvent("presence", "renewed Mac registration after active proof (last seen ${ageMs / 1000}s ago)")
                        continue
                    }
                    DebugTelemetry.recordEvent("presence", "demoted to offline after failed Mac proof (last seen ${ageMs / 1000}s ago)")
                    _uiState.update {
                        it.copy(
                            isConnectedToMac = false,
                            status = "Paired, offline",
                            androidReceiverStatus = "Mac stopped responding"
                        )
                    }
                }
            }
        }
        viewModelScope.launch {
            MacPresence.macFeatures.collect { features ->
                _uiState.update { it.copy(macFeatures = features) }
            }
        }
        viewModelScope.launch {
            // Recompute local feature health whenever a persisted toggle changes.
            preferences.settings.collect { refreshFeatureStatus() }
        }
        viewModelScope.launch {
            // The notification listener binds/unbinds asynchronously (e.g. after a forced rebind);
            // recompute so the dashboard flips off "On, but not receiving" as soon as it connects.
            NotificationMirrorState.connected.collect { refreshFeatureStatus() }
        }
        if (preferences.settings.value.clipboardSyncEnabled) {
            startClipboardSync()
        }
    }

    fun setAppearance(value: AppearancePreference) {
        preferences.setAppearance(value)
    }

    fun setAccentColor(hex: String) {
        preferences.setAccentColorHex(hex)
    }

    /** Recompute this phone's live feature health (permissions, listener bind state, FGS). */
    fun refreshFeatureStatus() {
        _uiState.update {
            it.copy(localFeatures = AndroidFeatureStatus.local(getApplication(), preferences.settings.value))
        }
    }

    /** Force the OS to rebind the notification listener when it silently dropped (e.g. reboot). */
    fun reconnectNotificationListener() {
        NotificationAccess.ensureListenerBound(getApplication())
        refreshFeatureStatus()
    }

    override fun onCleared() {
        stopClipboardSync()
        stopNetworkMonitor()
        discovery.stop()
        super.onCleared()
    }

    fun refreshPhoneControlStatus() {
        _uiState.update {
            it.copy(
                phoneControlStatus = PhonePermissions.status(getApplication()),
                localFeatures = AndroidFeatureStatus.local(getApplication(), preferences.settings.value)
            )
        }
    }

    private fun startNetworkMonitor() {
        val connectivity = getApplication<Application>().getSystemService(ConnectivityManager::class.java)
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = scheduleNetworkRefresh("available")

            override fun onLost(network: Network) = scheduleNetworkRefresh("lost")

            override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
                scheduleNetworkRefresh("capabilities")
            }
        }
        networkCallback = callback
        runCatching { connectivity.registerDefaultNetworkCallback(callback) }
            .onFailure { DebugTelemetry.recordEvent("network", "monitor failed: ${it.message}") }
    }

    private fun stopNetworkMonitor() {
        val callback = networkCallback ?: return
        networkCallback = null
        val connectivity = getApplication<Application>().getSystemService(ConnectivityManager::class.java)
        runCatching { connectivity.unregisterNetworkCallback(callback) }
    }

    private fun scheduleNetworkRefresh(reason: String) {
        if (_uiState.value.trustedMac == null) return
        DebugTelemetry.recordEvent("network", "change detected: $reason")
        networkRefreshJob?.cancel()
        networkRefreshJob = viewModelScope.launch {
            delay(750)
            discoverAndReconnect(force = true)
        }
    }

    fun setMacIp(value: String) {
        _uiState.update { it.copy(macIp = value, error = null, tokenRejected = false, networkHint = null) }
    }

    fun setPort(value: String) {
        _uiState.update { it.copy(port = value.filter(Char::isDigit).take(5), error = null, networkHint = null) }
    }

    fun setPairingToken(value: String) {
        _uiState.update { it.copy(pairingToken = value.trim(), error = null, tokenRejected = false, networkHint = null) }
    }

    fun pick(uri: Uri) {
        pick(listOf(uri))
    }

    fun pick(uris: List<Uri>) {
        runCatching {
            uris.map { getApplication<Application>().contentResolver.loadPickedFile(it) }
        }.onSuccess { files ->
            _uiState.update {
                it.copy(
                    pickedFiles = files,
                    status = if (files.size == 1) "Ready to send" else "Ready to send ${files.size} files",
                    error = null,
                    networkHint = null,
                    savedPath = null,
                    bytesSent = 0,
                    totalBytes = files.sumOf { file -> file.size },
                    currentFileName = null
                )
            }
        }.onFailure { error ->
            _uiState.update { it.copy(error = error.message ?: "Could not read selected file") }
        }
    }

    fun consumeShareIntent(intent: Intent?) {
        if (intent == null) return
        val uris = when (intent.action) {
            Intent.ACTION_SEND -> intent.streamUri()?.let(::listOf).orEmpty()
            Intent.ACTION_SEND_MULTIPLE -> intent.streamUris()
            else -> emptyList()
        }
        if (uris.isNotEmpty()) pick(uris)
    }

    fun pairManual() {
        _uiState.update {
            it.copy(
                error = "Manual token pairing is disabled. Scan the QR so Android can sign the Mac challenge.",
                networkHint = hotspotChecklist(),
                tokenRejected = true
            )
        }
    }

    fun pairFromQr(raw: String) {
        runCatching { PairingPayloadParser.parse(raw) }
            .onSuccess { payload ->
                _uiState.update {
                    it.copy(
                        macIp = payload.ip,
                        port = payload.port.toString(),
                        pairingToken = payload.pairingToken,
                        error = null,
                        networkHint = null
                    )
                }
                pair(payload)
            }
            .onFailure { error ->
                _uiState.update { it.copy(error = error.message ?: "Invalid Linkit QR", networkHint = hotspotChecklist()) }
            }
    }

    fun forgetMac() {
        val mac = identityStore.trustedMac()
        viewModelScope.launch {
            mac?.let {
                runCatching { client.disconnect(it, identityStore) }
            }
            LinkitReceiverService.stop(getApplication())
            identityStore.forgetTrustedMac()
            MacPresence.reset()
            _uiState.update {
                it.copy(
                    trustedMac = null,
                    isConnectedToMac = false,
                    status = "Pair with Mac",
                    savedPath = null,
                    networkHint = null,
                    androidReceiverStatus = "Pair with Mac to receive drops"
                )
            }
        }
    }

    fun disconnectMac() {
        val mac = _uiState.value.trustedMac ?: return
        viewModelScope.launch {
            _uiState.update { it.copy(status = "Disconnecting", error = null) }
            runCatching {
                client.disconnect(mac, identityStore)
            }.onSuccess {
                LinkitReceiverService.stop(getApplication())
                _uiState.update {
                    it.copy(
                        isConnectedToMac = false,
                        status = "Paired, offline",
                        androidReceiverStatus = "Disconnected from Mac"
                    )
                }
            }.onFailure { error ->
                LinkitReceiverService.stop(getApplication())
                _uiState.update {
                    it.copy(
                        isConnectedToMac = false,
                        status = "Paired, offline",
                        androidReceiverStatus = "Could not notify Mac: ${error.message}"
                    )
                }
            }
        }
    }

    fun connectMac() {
        if (_uiState.value.trustedMac == null) return
        _uiState.update { it.copy(status = "Connecting", androidReceiverStatus = "Connecting to Mac for drops", error = null, networkHint = null) }
        discoverAndReconnect(force = true)
    }

    private var reconnectJob: Job? = null

    fun discoverAndReconnect(force: Boolean = false) {
        val mac = _uiState.value.trustedMac ?: return
        if (_uiState.value.isPairing) return
        if (!force && _uiState.value.isConnectedToMac) return
        if (reconnectJob?.isActive == true) return
        _uiState.update {
            it.copy(
                status = "Looking for ${mac.deviceName}",
                androidReceiverStatus = "Looking for Mac on this network",
                error = null,
                networkHint = null
            )
        }
        DebugTelemetry.recordEvent("reconnect", "discover requested for ${mac.deviceName}")
        reconnectJob = viewModelScope.launch {
            val updated = MacRediscovery.rediscover(getApplication(), identityStore, client)
            val target = if (updated != null) {
                _uiState.update {
                    it.copy(
                        trustedMac = updated,
                        macIp = updated.ip,
                        port = updated.port.toString(),
                        status = "Connecting"
                    )
                }
                updated
            } else {
                _uiState.update { it.copy(status = "Trying last known address") }
                DebugTelemetry.recordEvent("reconnect", "using last known ${mac.ip}:${mac.port}")
                mac
            }
            registerAndroidReceiver(target)
        }
    }

    fun discoverMac() {
        _uiState.update { it.copy(status = "Discovering", error = null, networkHint = null) }
        discovery.start(
            onFound = { mac ->
                _uiState.update {
                    it.copy(macIp = mac.ip, port = mac.port.toString(), status = "Found ${mac.name}", error = null, networkHint = null)
                }
            },
            onError = { message ->
                _uiState.update { it.copy(status = "Discovery failed", error = message, networkHint = hotspotChecklist()) }
            }
        )
    }

    private fun pair(payload: MacPairingPayload) {
        if (_uiState.value.isPairing) return
        val ip = PrivateLanTarget.validateIp(payload.ip).getOrElse { error ->
            _uiState.update { it.copy(status = "Pairing failed", error = error.message, networkHint = hotspotChecklist()) }
            return
        }
        val port = PrivateLanTarget.validatePort(payload.port.toString()).getOrElse { error ->
            _uiState.update { it.copy(status = "Pairing failed", error = error.message, networkHint = hotspotChecklist()) }
            return
        }
        val expiresAt = payload.pairingTokenExpiresAt?.let { raw ->
            runCatching { Instant.parse(raw) }.getOrElse {
                _uiState.update { it.copy(status = "Pairing failed", error = "Pairing QR has an invalid expiry", networkHint = hotspotChecklist()) }
                return
            }
        }
        if (expiresAt != null && Instant.now().isAfter(expiresAt)) {
            _uiState.update {
                it.copy(status = "Pairing expired", error = "Refresh the QR on your Mac and scan again", tokenRejected = true, networkHint = hotspotChecklist())
            }
            return
        }
        val validatedPayload = payload.copy(ip = ip, port = port)

        viewModelScope.launch {
            _uiState.update { it.copy(isPairing = true, status = "Pairing", error = null, networkHint = null, tokenRejected = false) }
            try {
                val mac = client.pair(
                    baseUrl = PrivateLanTarget.baseUrl(validatedPayload.ip, validatedPayload.port),
                    payload = validatedPayload,
                    identityStore = identityStore,
                    batteryPercent = BatteryStatus.percent(getApplication())
                )
                identityStore.saveTrustedMac(mac)
                _uiState.update {
                    it.copy(
                        trustedMac = mac,
                        macIp = mac.ip,
                        port = mac.port.toString(),
                        isConnectedToMac = true,
                        isPairing = false,
                        status = "Connected",
                        androidReceiverStatus = "Mac drops enabled",
                        error = null,
                        networkHint = null,
                        tokenRejected = false
                    )
                }
                registerAndroidReceiver(mac)
            } catch (http: LinkitHttpException) {
                _uiState.update {
                    it.copy(isPairing = false, status = "Pairing failed", error = http.message, tokenRejected = http.statusCode == 401, networkHint = hotspotChecklist())
                }
            } catch (error: Throwable) {
                _uiState.update {
                    it.copy(isPairing = false, status = "Pairing failed", error = error.message, networkHint = hotspotChecklist())
                }
            }
        }
    }

    fun send() {
        if (sendJob?.isActive == true) return

        val state = _uiState.value
        val files = state.pickedFiles
        if (files.isEmpty()) {
            _uiState.update { it.copy(error = "Pick a file first") }
            return
        }
        val trusted = state.trustedMac
        if (trusted == null) {
            _uiState.update { it.copy(error = "Pair with your Mac first") }
            return
        }
        if (!state.isConnectedToMac) {
            _uiState.update { it.copy(error = "Connect to your Mac first") }
            return
        }
        val ip = PrivateLanTarget.validateIp(state.macIp).getOrElse { error ->
            _uiState.update { it.copy(error = error.message) }
            return
        }
        val port = PrivateLanTarget.validatePort(state.port).getOrElse { error ->
            _uiState.update { it.copy(error = error.message) }
            return
        }

        val mac = trusted.copy(ip = ip, port = port)
        identityStore.saveTrustedMac(mac)
        startedAtMillis = SystemClock.elapsedRealtime()
        sendJob = viewModelScope.launch {
            _uiState.update {
                it.copy(
                    isSending = true,
                    status = "Sending",
                    error = null,
                    networkHint = null,
                    savedPath = null,
                    tokenRejected = false,
                    bytesSent = 0,
                    totalBytes = files.sumOf { file -> file.size },
                    speedBytesPerSecond = 0.0,
                    etaSeconds = null,
                    currentFileName = null
                )
            }

            try {
                var completedBytes = 0L
                var lastSavedPath: String? = null
                for ((index, file) in files.withIndex()) {
                    _uiState.update {
                        it.copy(
                            currentFileName = file.name,
                            status = if (files.size > 1) "Sending ${index + 1}/${files.size}" else "Sending"
                        )
                    }
                    val result = try {
                        client.sendFile(
                            contentResolver = getApplication<Application>().contentResolver,
                            mac = mac,
                            identityStore = identityStore,
                            file = file,
                            onRetry = { message ->
                                _uiState.update { it.copy(status = message, speedBytesPerSecond = 0.0, etaSeconds = null) }
                                startedAtMillis = SystemClock.elapsedRealtime()
                            },
                            onProgress = { sent, _ ->
                                updateProgress(completedBytes + sent, files.sumOf { picked -> picked.size }, index + 1, files.size)
                            }
                        )
                    } catch (cancelled: CancellationException) {
                        recordSentHistory(file, mac, TransferHistoryEntry.STATUS_CANCELED, null, null)
                        throw cancelled
                    } catch (sendError: Throwable) {
                        recordSentHistory(file, mac, TransferHistoryEntry.STATUS_FAILED, null, sendError.message)
                        throw sendError
                    }
                    completedBytes += result.bytesSent
                    lastSavedPath = result.savedPath
                    recordSentHistory(file, mac, TransferHistoryEntry.STATUS_COMPLETE, result.savedPath, null)
                }

                _uiState.update {
                    it.copy(
                        isSending = false,
                        status = "Complete",
                        savedPath = lastSavedPath,
                        bytesSent = completedBytes,
                        totalBytes = completedBytes,
                        error = null,
                        networkHint = null,
                        etaSeconds = 0,
                        currentFileName = null
                    )
                }
            } catch (cancelled: CancellationException) {
                _uiState.update {
                    it.copy(isSending = false, status = "Canceled", error = null, etaSeconds = null, currentFileName = null)
                }
            } catch (tokenError: TokenRejectedException) {
                _uiState.update {
                    it.copy(
                        isSending = false,
                        status = "Token rejected",
                        error = tokenError.message,
                        tokenRejected = true,
                        etaSeconds = null,
                        currentFileName = null
                    )
                }
            } catch (http: LinkitHttpException) {
                _uiState.update {
                    it.copy(isSending = false, status = "Failed", error = http.message, etaSeconds = null, currentFileName = null)
                }
            } catch (io: IOException) {
                _uiState.update {
                    it.copy(isSending = false, status = "Network failed", error = io.message, networkHint = hotspotChecklist(), etaSeconds = null, currentFileName = null)
                }
            } catch (error: Throwable) {
                _uiState.update {
                    it.copy(isSending = false, status = "Failed", error = error.message, etaSeconds = null, currentFileName = null)
                }
            } finally {
                sendJob = null
            }
        }
    }

    fun cancelActive() {
        sendJob?.cancel()
    }

    fun sendClipboardTextToMac() {
        val text = currentClipboardText()
        if (text.isNullOrBlank()) {
            _uiState.update { it.copy(error = "Clipboard does not contain text") }
            return
        }
        sendActionToMac("clipboard", text, "Clipboard sent")
    }

    fun openClipboardLinkOnMac() {
        val text = currentClipboardText()?.trim()
        val uri = text?.let(Uri::parse)
        val scheme = uri?.scheme?.lowercase()
        if (text.isNullOrBlank() || (scheme != "http" && scheme != "https")) {
            _uiState.update { it.copy(error = "Clipboard does not contain an http or https URL") }
            return
        }
        sendActionToMac("open_url", text, "Opening link on Mac")
    }

    fun toggleClipboardSync() {
        if (_uiState.value.clipboardSyncEnabled) {
            stopClipboardSync()
            preferences.setClipboardSyncEnabled(false)
            _uiState.update { it.copy(clipboardSyncEnabled = false, status = "Clipboard sync off") }
            return
        }
        startClipboardSync()
        preferences.setClipboardSyncEnabled(true)
        _uiState.update { it.copy(status = "Clipboard sync on", error = null) }
    }

    fun setNotificationMirrorEnabled(enabled: Boolean) {
        preferences.setNotificationMirrorEnabled(enabled)
        // Turning it on should also recover a listener the OS may have dropped, so mirroring
        // actually resumes instead of just flipping a toggle over a dead listener.
        if (enabled) NotificationAccess.ensureListenerBound(getApplication())
        _uiState.update {
            it.copy(status = if (enabled) "Notification mirroring on" else "Notification mirroring off")
        }
        refreshFeatureStatus()
    }

    private fun startClipboardSync() {
        if (clipboardListener != null) return
        val clipboard = getApplication<Application>().getSystemService(ClipboardManager::class.java)
        lastClipboardText = currentClipboardText()
        val listener = ClipboardManager.OnPrimaryClipChangedListener {
            val text = currentClipboardText()
            if (!text.isNullOrBlank() && text != lastClipboardText && text.toByteArray(Charsets.UTF_8).size <= 128 * 1024) {
                lastClipboardText = text
                sendActionToMac("clipboard", text, "Clipboard synced")
            }
        }
        clipboard.addPrimaryClipChangedListener(listener)
        clipboardListener = listener
        _uiState.update { it.copy(clipboardSyncEnabled = true, error = null) }
    }

    private fun stopClipboardSync() {
        val listener = clipboardListener ?: return
        getApplication<Application>().getSystemService(ClipboardManager::class.java)
            .removePrimaryClipChangedListener(listener)
        clipboardListener = null
    }

    private fun currentClipboardText(): String? {
        val clipboard = getApplication<Application>().getSystemService(ClipboardManager::class.java)
        val item = clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0) ?: return null
        return item.coerceToText(getApplication())?.toString()?.trim()
    }

    private fun sendActionToMac(type: String, text: String, successStatus: String) {
        val mac = _uiState.value.trustedMac
        if (mac == null || !_uiState.value.isConnectedToMac) {
            _uiState.update { it.copy(error = "Connect to your Mac first") }
            return
        }
        viewModelScope.launch {
            runCatching {
                client.sendAction(mac, identityStore, type, text)
            }.onSuccess {
                _uiState.update { it.copy(status = successStatus, error = null, networkHint = null) }
            }.onFailure { error ->
                if (_uiState.value.clipboardSyncEnabled) {
                    stopClipboardSync()
                }
                _uiState.update {
                    it.copy(
                        clipboardSyncEnabled = false,
                        status = "Handoff failed",
                        error = error.message,
                        networkHint = hotspotChecklist()
                    )
                }
            }
        }
    }

    private fun localFeatures(): List<FeatureStatus> =
        AndroidFeatureStatus.local(getApplication(), preferences.settings.value)

    private fun registerAndroidReceiver(mac: TrustedMac) {
        LinkitReceiverService.start(getApplication())
        viewModelScope.launch {
            runCatching {
                client.verifyMacEndpoint(mac)
                client.registerReceiver(
                    mac = mac,
                    identityStore = identityStore,
                    receivePort = AndroidDropReceiver.PORT,
                    batteryPercent = BatteryStatus.percent(getApplication()),
                    features = localFeatures()
                )
            }.onSuccess {
                _uiState.update { state ->
                    state.copy(
                        isConnectedToMac = true,
                        status = if (state.isSending || state.isPairing) state.status else "Connected",
                        androidReceiverStatus = "Mac drops enabled",
                        networkHint = null
                    )
                }
            }.onFailure { error ->
                DebugTelemetry.recordEvent("reconnect", "register failed: ${error.message}")
                _uiState.update { state ->
                    state.copy(
                        isConnectedToMac = false,
                        status = if (state.trustedMac == null) "Pair with Mac" else "Paired, offline",
                        androidReceiverStatus = "Open Linkit on Mac to connect: ${error.message}",
                        networkHint = hotspotChecklist()
                    )
                }
            }
        }
    }

    fun clearHistory() {
        history.clear()
    }

    fun checkForAndroidUpdate() {
        if (_uiState.value.isCheckingUpdate || _uiState.value.isInstallingUpdate) return
        viewModelScope.launch(Dispatchers.IO) {
            _uiState.update {
                it.copy(isCheckingUpdate = true, updateStatus = "Checking for updates", updateError = null)
            }
            runCatching {
                appUpdater.checkForUpdates()
            }.onSuccess { result ->
                _uiState.update { state ->
                    when (result) {
                        AndroidUpdateCheckResult.UpToDate -> state.copy(
                            isCheckingUpdate = false,
                            availableAndroidUpdate = null,
                            updateStatus = "Linkit is up to date",
                            updateError = null
                        )
                        is AndroidUpdateCheckResult.Available -> state.copy(
                            isCheckingUpdate = false,
                            availableAndroidUpdate = result.update,
                            updateStatus = "Version ${result.update.versionName} (${result.update.versionCode}) is available",
                            updateError = null
                        )
                    }
                }
            }.onFailure { error ->
                _uiState.update {
                    it.copy(
                        isCheckingUpdate = false,
                        updateStatus = "Update check failed",
                        updateError = error.message ?: "Could not check for updates"
                    )
                }
            }
        }
    }

    fun installAndroidUpdate() {
        if (_uiState.value.isInstallingUpdate) return
        val update = _uiState.value.availableAndroidUpdate ?: return checkForAndroidUpdate()
        viewModelScope.launch(Dispatchers.IO) {
            _uiState.update {
                it.copy(isInstallingUpdate = true, updateStatus = "Downloading update", updateError = null)
            }
            runCatching {
                val apk = appUpdater.download(update)
                _uiState.update { it.copy(updateStatus = "Opening installer") }
                withContext(Dispatchers.Main) {
                    appUpdater.install(apk)
                }
            }.onSuccess {
                _uiState.update {
                    it.copy(isInstallingUpdate = false, updateStatus = "Installer opened", updateError = null)
                }
            }.onFailure { error ->
                _uiState.update {
                    it.copy(
                        isInstallingUpdate = false,
                        updateStatus = "Update install paused",
                        updateError = error.message ?: "Could not install update"
                    )
                }
            }
        }
    }

    private fun recordSentHistory(file: PickedFile, mac: TrustedMac, status: String, savedPath: String?, error: String?) {
        viewModelScope.launch(Dispatchers.IO) {
            history.append(
                TransferHistoryEntry(
                    id = "snd_${UUID.randomUUID()}",
                    direction = TransferHistoryEntry.DIRECTION_SENT,
                    filename = file.name,
                    size = file.size,
                    peerName = mac.deviceName,
                    completedAt = System.currentTimeMillis(),
                    status = status,
                    savedPath = savedPath,
                    error = error
                )
            )
        }
    }

    private fun handleDropEvent(event: AndroidDropEvent) {
        _uiState.update {
            it.copy(
                androidReceiverStatus = event.error ?: event.status,
                lastAndroidDropPath = event.savedPath ?: it.lastAndroidDropPath
            )
        }
    }

    private fun updateProgress(sent: Long, total: Long, fileNumber: Int = 1, fileCount: Int = 1) {
        val elapsedSeconds = max(0.001, (SystemClock.elapsedRealtime() - startedAtMillis) / 1000.0)
        val speed = sent / elapsedSeconds
        val remaining = max(0, total - sent)
        val eta = if (speed > 1) (remaining / speed).roundToLong() else null
        _uiState.update {
            it.copy(
                bytesSent = sent,
                totalBytes = total,
                speedBytesPerSecond = speed,
                etaSeconds = eta,
                status = if (fileCount > 1) "Sending $fileNumber/$fileCount" else "Sending"
            )
        }
    }

    private fun hotspotChecklist(): String {
        return "Hotspot mode: turn on the phone hotspot, connect the Mac to it, open Linkit on Mac, then scan a fresh QR. If discovery fails, use the IP shown in Mac diagnostics."
    }
}

private fun Intent.streamUri(): Uri? {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
    } else {
        @Suppress("DEPRECATION")
        getParcelableExtra(Intent.EXTRA_STREAM)
    }
}

private fun Intent.streamUris(): List<Uri> {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
    } else {
        @Suppress("DEPRECATION")
        getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
    }
}

/* ------------------------------------------------------------------------- *
 * UI · Linkit · macrostructure: bottom-nav shell (Home · Activity · Settings)
 *   Home = control surface, Activity = transfers, Settings = hub → detail.
 *   The bottom bar is the always-visible "map" — Android's answer to the Mac
 *   Settings sidebar. Each Settings category drills into a focused detail
 *   screen instead of one long scroll.
 *   theme: warm paper light / charcoal dark · accent-driven primary
 * ------------------------------------------------------------------------- */

/** Top-level destinations shown in the bottom navigation bar. */
private enum class TopTab { HOME, ACTIVITY, SETTINGS }

/** The Settings tab is a hub that pushes one of these focused detail screens. */
private enum class SettingsRoute { HUB, DEVICE, CLIPBOARD, NOTIFICATIONS, PHONE, APPEARANCE, BACKGROUND, UPDATES, ABOUT }

@Composable
private fun LinkitScreen(
    viewModel: LinkitViewModel,
    onEnablePhoneControls: () -> Unit
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val history by viewModel.historyEntries.collectAsStateWithLifecycle()
    val settings by viewModel.settings.collectAsStateWithLifecycle()
    val context = LocalContext.current

    var topTab by rememberSaveable { mutableStateOf(TopTab.HOME) }
    var settingsRoute by rememberSaveable { mutableStateOf(SettingsRoute.HUB) }

    val filePicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty()) {
            runCatching {
                uris.forEach { uri ->
                    context.contentResolver.takePersistableUriPermission(
                        uri, Intent.FLAG_GRANT_READ_URI_PERMISSION
                    )
                }
            }
            viewModel.pick(uris)
            viewModel.send()
        }
    }
    val qrScanner = rememberLauncherForActivityResult(ScanContract()) { result ->
        result.contents?.let(viewModel::pairFromQr)
    }
    val launchQrScanner = {
        qrScanner.launch(
            ScanOptions()
                .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                .setPrompt("Point at the Linkit QR on your Mac")
                .setBeepEnabled(false)
                .setCaptureActivity(PortraitCaptureActivity::class.java)
                .setOrientationLocked(false)
        )
    }

    val openSettingsDetail: (SettingsRoute) -> Unit = { route ->
        settingsRoute = route
        topTab = TopTab.SETTINGS
    }

    // Sending is cancelable with Back, and always wins over navigation.
    BackHandler(enabled = state.isSending) { viewModel.cancelActive() }

    if (state.trustedMac == null) {
        Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box(modifier = Modifier.fillMaxSize().systemBarsPadding()) {
                WelcomeScreen(isPairing = state.isPairing, error = state.error, onPair = launchQrScanner)
            }
        }
        return
    }

    // Back walks the hierarchy: detail → hub, then any tab → Home, then exit.
    BackHandler(enabled = !state.isSending && (topTab != TopTab.HOME || settingsRoute != SettingsRoute.HUB)) {
        when {
            topTab == TopTab.SETTINGS && settingsRoute != SettingsRoute.HUB -> settingsRoute = SettingsRoute.HUB
            topTab != TopTab.HOME -> topTab = TopTab.HOME
        }
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        bottomBar = {
            LinkitBottomBar(
                current = topTab,
                onSelect = { tab ->
                    // Tapping the Settings tab always returns to the hub.
                    if (tab == TopTab.SETTINGS) settingsRoute = SettingsRoute.HUB
                    topTab = tab
                }
            )
        }
    ) { innerPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
        ) {
            when (topTab) {
                TopTab.HOME -> HomeTab(
                    state = state,
                    onPickFile = { filePicker.launch(arrayOf("*/*")) },
                    onSendClipboard = viewModel::sendClipboardTextToMac,
                    onOpenLink = viewModel::openClipboardLinkOnMac,
                    onToggleClipboardSync = viewModel::toggleClipboardSync,
                    onReconnect = viewModel::discoverAndReconnect,
                    onReconnectNotificationListener = viewModel::reconnectNotificationListener,
                    onEnablePhoneControls = onEnablePhoneControls
                )
                TopTab.ACTIVITY -> ActivityTab(history = history, onClear = viewModel::clearHistory)
                TopTab.SETTINGS -> SettingsTab(
                    route = settingsRoute,
                    state = state,
                    settings = settings,
                    onOpenDetail = { settingsRoute = it },
                    onBackToHub = { settingsRoute = SettingsRoute.HUB },
                    onReconnect = { viewModel.discoverAndReconnect() },
                    onDisconnect = viewModel::disconnectMac,
                    onRePair = launchQrScanner,
                    onForget = { topTab = TopTab.HOME; settingsRoute = SettingsRoute.HUB; viewModel.forgetMac() },
                    onToggleClipboardSync = viewModel::toggleClipboardSync,
                    onSetNotificationMirror = viewModel::setNotificationMirrorEnabled,
                    onSetAppearance = viewModel::setAppearance,
                    onCheckUpdate = viewModel::checkForAndroidUpdate,
                    onInstallUpdate = viewModel::installAndroidUpdate,
                    onEnablePhoneControls = onEnablePhoneControls,
                    onSetAccent = viewModel::setAccentColor
                )
            }

            AnimatedVisibility(
                visible = state.isSending,
                enter = slideInVertically(initialOffsetY = { it }) + fadeIn(),
                exit = slideOutVertically(targetOffsetY = { it }) + fadeOut(),
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(16.dp)
            ) {
                TransferBar(state = state, onCancel = viewModel::cancelActive)
            }
        }
    }
}

/** The persistent bottom navigation — the app's always-visible map. */
@Composable
private fun LinkitBottomBar(current: TopTab, onSelect: (TopTab) -> Unit) {
    NavigationBar(
        containerColor = MaterialTheme.colorScheme.surface,
        tonalElevation = 0.dp
    ) {
        val items = listOf(
            Triple(TopTab.HOME, Icons.Rounded.Home, "Home"),
            Triple(TopTab.ACTIVITY, Icons.Rounded.SwapVert, "Activity"),
            Triple(TopTab.SETTINGS, Icons.Rounded.Settings, "Settings")
        )
        items.forEach { (tab, icon, label) ->
            NavigationBarItem(
                selected = current == tab,
                onClick = { onSelect(tab) },
                icon = { Icon(icon, contentDescription = label, modifier = Modifier.size(22.dp)) },
                label = { Text(label, fontSize = 11.sp, fontWeight = FontWeight.Medium) },
                colors = NavigationBarItemDefaults.colors(
                    selectedIconColor = MaterialTheme.colorScheme.onPrimary,
                    selectedTextColor = MaterialTheme.colorScheme.primary,
                    indicatorColor = MaterialTheme.colorScheme.primary,
                    unselectedIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
                    unselectedTextColor = MaterialTheme.colorScheme.onSurfaceVariant
                )
            )
        }
    }
}

@Composable
private fun WelcomeScreen(
    isPairing: Boolean,
    error: String?,
    onPair: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 28.dp, vertical = 24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Box(
            modifier = Modifier
                .size(88.dp)
                .clip(RoundedCornerShape(22.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant),
            contentAlignment = Alignment.Center
        ) {
            Image(
                painter = painterResource(R.mipmap.ic_launcher),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize().clip(RoundedCornerShape(22.dp))
            )
        }
        Spacer(modifier = Modifier.height(28.dp))
        Text(
            "Linkit",
            style = MaterialTheme.typography.displaySmall,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onBackground
        )
        Spacer(modifier = Modifier.height(10.dp))
        Text(
            "Send files, clipboard, and links between your Mac and Android. Pair once — reconnects when you're on the same network.",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 8.dp)
        )
        Spacer(modifier = Modifier.height(36.dp))
        Button(
            onClick = onPair,
            enabled = !isPairing,
            shape = RoundedCornerShape(14.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = MaterialTheme.colorScheme.primary,
                contentColor = MaterialTheme.colorScheme.onPrimary,
                disabledContainerColor = MaterialTheme.colorScheme.surfaceVariant,
                disabledContentColor = MaterialTheme.colorScheme.onSurfaceVariant
            ),
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 56.dp)
        ) {
            Text(
                if (isPairing) "Pairing…" else "Pair with Mac",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Medium
            )
        }
        Spacer(modifier = Modifier.height(12.dp))
        Text(
            "Open Linkit on your Mac and choose “Show pairing QR”.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.72f),
            textAlign = TextAlign.Center
        )
        error?.let {
            Spacer(modifier = Modifier.height(20.dp))
            ErrorBanner(it)
        }
    }
}

@Composable
private fun HomeTab(
    state: LinkitUiState,
    onPickFile: () -> Unit,
    onSendClipboard: () -> Unit,
    onOpenLink: () -> Unit,
    onToggleClipboardSync: () -> Unit,
    onReconnect: () -> Unit,
    onReconnectNotificationListener: () -> Unit,
    onEnablePhoneControls: () -> Unit
) {
    val context = LocalContext.current
    var resolveTarget by remember { mutableStateOf<FeatureStatus?>(null) }
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp)
            .padding(bottom = if (state.isSending) 120.dp else 24.dp)
    ) {
        HomeWordmark()
        Spacer(modifier = Modifier.height(4.dp))
        DeviceCard(state = state, onReconnect = onReconnect)
        Spacer(modifier = Modifier.height(20.dp))
        ActionGrid(
            enabled = state.isConnectedToMac,
            clipboardSyncOn = state.clipboardSyncEnabled,
            onPickFile = onPickFile,
            onSendClipboard = onSendClipboard,
            onOpenLink = onOpenLink,
            onToggleClipboardSync = onToggleClipboardSync
        )
        state.error?.takeIf { !state.isSending }?.let {
            Spacer(modifier = Modifier.height(16.dp))
            ErrorBanner(it)
        }
        Spacer(modifier = Modifier.height(28.dp))
        // Compact feature health, kept at the bottom so Home stays uncluttered.
        // A feature with a problem shows a red dot + chevron; tapping opens a dialog
        // that explains how to resolve it.
        HomeFeatureStatus(features = state.localFeatures, onResolve = { resolveTarget = it })
    }

    resolveTarget?.let { feature ->
        FeatureResolveDialog(
            feature = feature,
            onFix = {
                resolveFeatureAction(
                    context = context,
                    feature = feature,
                    onReconnectNotificationListener = onReconnectNotificationListener,
                    onEnablePhoneControls = onEnablePhoneControls
                )
                resolveTarget = null
            },
            onDismiss = { resolveTarget = null }
        )
    }
}

/** Compact feature-health list: title + status dot, red chevron only when broken. */
@Composable
private fun HomeFeatureStatus(features: List<FeatureStatus>, onResolve: (FeatureStatus) -> Unit) {
    SettingsGroupCard(label = "Feature status") {
        features.forEachIndexed { index, feature ->
            if (index > 0) LinkitRowDivider()
            HomeFeatureRow(feature = feature, onResolve = onResolve)
        }
    }
}

@Composable
private fun HomeFeatureRow(feature: FeatureStatus, onResolve: (FeatureStatus) -> Unit) {
    val attention = feature.state == FeatureState.ATTENTION
    val dotColor = when (feature.state) {
        FeatureState.ON -> MaterialTheme.colorScheme.tertiary
        FeatureState.ATTENTION -> MaterialTheme.colorScheme.error
        FeatureState.OFF -> MaterialTheme.colorScheme.outline
        FeatureState.UNSUPPORTED -> MaterialTheme.colorScheme.outline.copy(alpha = 0.5f)
    }
    val base = Modifier.fillMaxWidth()
    val row = if (attention) base.clickable { onResolve(feature) } else base
    Row(
        modifier = row.padding(horizontal = 16.dp, vertical = 13.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            modifier = Modifier
                .size(9.dp)
                .clip(CircleShape)
                .background(dotColor)
        )
        Text(
            feature.title,
            style = MaterialTheme.typography.bodyLarge,
            fontWeight = FontWeight.Medium,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f)
        )
        if (attention) {
            Icon(
                imageVector = Icons.Rounded.ChevronRight,
                contentDescription = "Resolve",
                tint = MaterialTheme.colorScheme.error,
                modifier = Modifier.size(20.dp)
            )
        }
    }
}

/** Explains what a broken feature needs and offers a single Fix action. */
@Composable
private fun FeatureResolveDialog(feature: FeatureStatus, onFix: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(feature.title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
        },
        text = {
            Text(
                feature.detail,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        },
        confirmButton = { TextButton(onClick = onFix) { Text("Fix") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Close") } }
    )
}

/** The "Linkit" wordmark with the hidden 7-tap debug entry point. */
@Composable
private fun HomeWordmark() {
    val context = LocalContext.current
    var tapCount by remember { mutableStateOf(0) }
    var lastTapMillis by remember { mutableStateOf(0L) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            "Linkit",
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onBackground,
            modifier = Modifier.clickable {
                val now = SystemClock.elapsedRealtime()
                tapCount = if (now - lastTapMillis > 1_500) 1 else tapCount + 1
                lastTapMillis = now
                if (tapCount >= 7) {
                    tapCount = 0
                    context.startActivity(Intent(context, DebugActivity::class.java))
                }
            }
        )
    }
}

@Composable
private fun ActivityTab(history: List<TransferHistoryEntry>, onClear: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp)
            .padding(top = 8.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp)
    ) {
        LinkitLargeHeader(title = "Activity", subtitle = "Files sent and received between your devices.")
        SettingsGroupCard(label = "Received files") {
            LinkitCardRow(
                icon = Icons.Rounded.Download,
                title = "Save location",
                subtitle = "Downloads/Linkit Drop",
                accent = MaterialTheme.colorScheme.primary
            ) {}
        }
        RecentActivity(entries = history, onClear = onClear)
    }
}

@Composable
private fun DeviceCard(state: LinkitUiState, onReconnect: () -> Unit) {
    val mac = state.trustedMac ?: return
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(20.dp))
            .background(MaterialTheme.colorScheme.surface)
            .border(
                BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                RoundedCornerShape(20.dp)
            )
            .padding(18.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(13.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            DeviceAvatar(name = mac.deviceName, connected = state.isConnectedToMac)
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(3.dp)
            ) {
                Text(
                    mac.deviceName,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                StatusLine(state)
            }
        }
        if (!state.isConnectedToMac) {
            Button(
                onClick = onReconnect,
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = MaterialTheme.colorScheme.primary,
                    contentColor = MaterialTheme.colorScheme.onPrimary
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 48.dp)
            ) {
                val isWorking = state.status.startsWith("Looking") ||
                    state.status.startsWith("Connecting") ||
                    state.status.startsWith("Trying")
                Text(
                    if (isWorking) state.status else "Reconnect",
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.Medium
                )
            }
        }
    }
}

@Composable
private fun DeviceAvatar(name: String, connected: Boolean) {
    val accent = MaterialTheme.colorScheme.primary
    Box(modifier = Modifier.size(52.dp)) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .clip(RoundedCornerShape(15.dp))
                .background(if (connected) accentGradient(accent) else accentGradient(MaterialTheme.colorScheme.outline)),
            contentAlignment = Alignment.Center
        ) {
            // The paired peer is a Mac — mirror the Mac app, which shows this phone with an
            // iPhone glyph on the same accent-gradient tile.
            Icon(
                imageVector = Icons.Rounded.LaptopMac,
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(26.dp)
            )
        }
        if (connected) {
            Box(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .size(14.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.background)
                    .padding(2.dp)
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.tertiary)
                )
            }
        }
    }
}

@Composable
private fun StatusLine(state: LinkitUiState) {
    val (label, dotColor, animated) = when {
        state.isConnectedToMac -> StatusVisual("Connected", MaterialTheme.colorScheme.tertiary, true)
        state.status.startsWith("Looking") ||
            state.status.startsWith("Connecting") ||
            state.status.startsWith("Trying") ||
            state.status.startsWith("Disconnecting") ||
            state.status == "Discovering" ->
                StatusVisual(state.status, MaterialTheme.colorScheme.primary, true)
        else -> StatusVisual("Offline", MaterialTheme.colorScheme.outline, false)
    }
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        PulseDot(color = dotColor, animated = animated)
        Text(
            label,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}

private data class StatusVisual(val label: String, val color: Color, val animated: Boolean)

@Composable
private fun PulseDot(color: Color, animated: Boolean) {
    val alpha = if (animated) {
        val transition = rememberInfiniteTransition(label = "status-pulse")
        val anim = transition.animateFloat(
            initialValue = 1f,
            targetValue = 0.35f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = 1400, easing = LinearEasing),
                repeatMode = RepeatMode.Reverse
            ),
            label = "alpha"
        )
        anim.value
    } else 1f
    Box(
        modifier = Modifier
            .size(8.dp)
            .clip(CircleShape)
            .background(color.copy(alpha = alpha))
    )
}

@Composable
private fun ActionGrid(
    enabled: Boolean,
    clipboardSyncOn: Boolean,
    onPickFile: () -> Unit,
    onSendClipboard: () -> Unit,
    onOpenLink: () -> Unit,
    onToggleClipboardSync: () -> Unit
) {
    val accent = MaterialTheme.colorScheme.primary
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            QuickActionTile(icon = Icons.Rounded.UploadFile, title = "Send File", enabled = enabled, onClick = onPickFile, modifier = Modifier.weight(1f))
            QuickActionTile(icon = Icons.Rounded.ContentPaste, title = "Clipboard", enabled = enabled, onClick = onSendClipboard, modifier = Modifier.weight(1f))
            QuickActionTile(icon = Icons.Rounded.Link, title = "Open Link", enabled = enabled, onClick = onOpenLink, modifier = Modifier.weight(1f))
        }
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(MaterialTheme.colorScheme.surface)
                .border(BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant), RoundedCornerShape(16.dp))
        ) {
            LinkitToggleRow(
                icon = Icons.Rounded.Sync,
                title = "Clipboard Sync",
                subtitle = "Copy on Mac → paste on Android, and vice-versa while Linkit is open.",
                accent = accent,
                checked = clipboardSyncOn,
                enabled = enabled || clipboardSyncOn,
                onCheckedChange = { onToggleClipboardSync() }
            )
        }
    }
}

@Composable
private fun QuickActionTile(
    icon: ImageVector,
    title: String,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val base = modifier
        .heightIn(min = 78.dp)
        .clip(RoundedCornerShape(14.dp))
        .background(MaterialTheme.colorScheme.surface)
        .border(BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant), RoundedCornerShape(14.dp))
    val interactive = if (enabled) base.clickable(onClick = onClick) else base
    val contentColor = MaterialTheme.colorScheme.onSurface.copy(alpha = if (enabled) 1f else 0.4f)
    Column(
        modifier = interactive.padding(vertical = 14.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = contentColor,
            modifier = Modifier.size(22.dp)
        )
        Text(
            title,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            color = contentColor
        )
    }
}


@Composable
private fun PhoneControlsSection(
    status: PhoneControlPermissionStatus,
    onEnable: () -> Unit
) {
    val accent = MaterialTheme.colorScheme.primary
    val needsPermission = !status.canWatchCalls ||
        !status.canPlaceDirectCalls ||
        !status.canControlCalls ||
        !status.canSeeNumbers ||
        !status.canResolveContacts
    SettingsGroupCard(label = "Phone") {
        LinkitCardRow(
            icon = Icons.Rounded.Call,
            title = "Call controls",
            subtitle = status.summary,
            accent = accent
        ) {}
        LinkitRowDivider()
        LinkitCardRow(
            icon = Icons.Rounded.Tune,
            title = "Caller ID & controls",
            subtitle = buildString {
                append("Incoming: ")
                append(if (status.canWatchCalls) "On" else "Off")
                append("  ·  Direct call: ")
                append(if (status.canPlaceDirectCalls) "On" else "Dialer")
                append("  ·  Controls: ")
                append(if (status.canControlCalls) "On" else "Off")
                append("  ·  Caller ID: ")
                append(
                    when {
                        status.canSeeNumbers && status.canResolveContacts -> "On"
                        status.canSeeNumbers -> "Number only"
                        else -> "Off"
                    }
                )
            },
            accent = accent
        ) {}
        if (needsPermission) {
            LinkitRowDivider()
            LinkitCardRow(icon = Icons.Rounded.LockOpen, title = "Enable phone controls", accent = accent, onClick = onEnable) { RowChevron() }
        }
    }
}

@Composable
private fun UpdateSection(state: LinkitUiState, onCheck: () -> Unit, onInstall: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(18.dp))
                .background(MaterialTheme.colorScheme.surface)
                .border(
                    BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                    RoundedCornerShape(18.dp)
                )
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Text(
                text = "Current ${state.currentAndroidVersion}",
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurface
            )
            Text(
                text = state.updateStatus,
                style = MaterialTheme.typography.bodyMedium,
                color = if (state.updateError == null) {
                    MaterialTheme.colorScheme.onSurfaceVariant
                } else {
                    MaterialTheme.colorScheme.error
                },
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
            state.availableAndroidUpdate?.manifest?.releaseNotes?.takeIf { it.isNotBlank() }?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis
                )
            }
            state.updateError?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error
                )
            }
            if (state.isCheckingUpdate || state.isInstallingUpdate) {
                LinearProgressIndicator(
                    color = MaterialTheme.colorScheme.primary,
                    trackColor = MaterialTheme.colorScheme.outlineVariant,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(6.dp)
                        .clip(RoundedCornerShape(999.dp))
                )
            }
            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                OutlinedButton(
                    onClick = onCheck,
                    enabled = !state.isCheckingUpdate && !state.isInstallingUpdate,
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.weight(1f)
                ) {
                    Text(if (state.isCheckingUpdate) "Checking…" else "Check")
                }
                Button(
                    onClick = onInstall,
                    enabled = state.availableAndroidUpdate != null &&
                        !state.isCheckingUpdate &&
                        !state.isInstallingUpdate,
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.weight(1f)
                ) {
                    Text(if (state.isInstallingUpdate) "Installing…" else "Install")
                }
            }
        }
    }
}

@Composable
private fun RecentActivity(entries: List<TransferHistoryEntry>, onClear: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                "RECENT",
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
                letterSpacing = 0.9.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 6.dp)
            )
            if (entries.isNotEmpty()) {
                TextButton(onClick = onClear) {
                    Text(
                        "Clear",
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.primary
                    )
                }
            }
        }
        if (entries.isEmpty()) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(18.dp))
                    .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.6f))
                    .border(
                        BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
                        RoundedCornerShape(18.dp)
                    )
                    .padding(vertical = 28.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    "Files and handoffs will appear here.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        } else {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(18.dp))
                    .background(MaterialTheme.colorScheme.surface)
                    .border(
                        BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                        RoundedCornerShape(18.dp)
                    )
            ) {
                val shown = entries.take(8)
                shown.forEachIndexed { index, entry ->
                    ActivityRow(entry)
                    if (index < shown.lastIndex) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(1.dp)
                                .background(MaterialTheme.colorScheme.outlineVariant)
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ActivityRow(entry: TransferHistoryEntry) {
    val isSent = entry.direction == TransferHistoryEntry.DIRECTION_SENT
    val accent = if (isSent) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.tertiary
    val context = LocalContext.current
    val openableUri = entry.contentUri
        ?.takeIf { entry.direction == TransferHistoryEntry.DIRECTION_RECEIVED && entry.status == TransferHistoryEntry.STATUS_COMPLETE }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .let { base ->
                if (openableUri != null) base.clickable { openReceivedFile(context, openableUri) } else base
            }
            .padding(horizontal = 14.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            modifier = Modifier
                .size(30.dp)
                .clip(CircleShape)
                .background(accent.copy(alpha = 0.14f)),
            contentAlignment = Alignment.Center
        ) {
            Text(
                if (isSent) "↑" else "↓",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
                color = accent
            )
        }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                entry.filename,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            Text(
                buildString {
                    append(formatBytes(entry.size))
                    append("  ·  ")
                    append(formatRelative(entry.completedAt))
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
        when (entry.status) {
            TransferHistoryEntry.STATUS_FAILED -> Text(
                "Failed",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.error
            )
            TransferHistoryEntry.STATUS_COMPLETE -> Unit
            else -> Text(
                entry.status.replaceFirstChar { it.uppercase() },
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

private fun openReceivedFile(context: Context, uriString: String) {
    val uri = runCatching { Uri.parse(uriString) }.getOrNull() ?: return
    val mimeType = context.contentResolver.getType(uri) ?: "*/*"
    val intent = Intent(Intent.ACTION_VIEW).apply {
        setDataAndType(uri, mimeType)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    val opened = runCatching { context.startActivity(intent); true }.getOrDefault(false)
    if (!opened) {
        Toast.makeText(context, "No app can open this file", Toast.LENGTH_SHORT).show()
    }
}

@Composable
private fun TransferBar(state: LinkitUiState, onCancel: () -> Unit) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = MaterialTheme.colorScheme.surface,
        shape = RoundedCornerShape(20.dp),
        tonalElevation = 6.dp,
        shadowElevation = 8.dp,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        state.currentFileName ?: "Sending",
                        style = MaterialTheme.typography.bodyLarge,
                        fontWeight = FontWeight.Medium,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    val pct = if (state.totalBytes > 0) {
                        ((state.bytesSent.toDouble() / state.totalBytes) * 100).toInt()
                    } else 0
                    Text(
                        buildString {
                            append("$pct%  ·  ")
                            append("${formatBytes(state.bytesSent)} / ${formatBytes(state.totalBytes)}")
                            state.etaSeconds?.takeIf { it > 0 }?.let {
                                append("  ·  ${formatEta(it)} left")
                            }
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                TextButton(onClick = onCancel) {
                    Text(
                        "Cancel",
                        color = MaterialTheme.colorScheme.error,
                        fontWeight = FontWeight.Medium
                    )
                }
            }
            val progress = if (state.totalBytes > 0) {
                (state.bytesSent.toFloat() / state.totalBytes.toFloat()).coerceIn(0f, 1f)
            } else 0f
            LinearProgressIndicator(
                progress = { progress },
                color = MaterialTheme.colorScheme.primary,
                trackColor = MaterialTheme.colorScheme.outlineVariant,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(6.dp)
                    .clip(RoundedCornerShape(999.dp))
            )
        }
    }
}

@Composable
private fun ErrorBanner(message: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(MaterialTheme.colorScheme.errorContainer)
            .padding(14.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top
    ) {
        Icon(
            imageVector = Icons.Rounded.ErrorOutline,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.error,
            modifier = Modifier.size(20.dp)
        )
        Text(
            message,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onErrorContainer,
            modifier = Modifier.weight(1f)
        )
    }
}

/* ------------------------------------------------------------------------- *
 * UI · Settings · dedicated screen pushed from the Home gear icon
 *   grouped, Android-Settings-style sections mirroring the Mac Settings window
 * ------------------------------------------------------------------------- */

/* ------------------------------------------------------------------------- *
 * UI · Settings · hub → detail
 *   The Settings tab shows a short hub of categories; each drills into a
 *   focused detail screen (mirrors the Mac Settings sidebar sections).
 * ------------------------------------------------------------------------- */

@Composable
private fun SettingsTab(
    route: SettingsRoute,
    state: LinkitUiState,
    settings: LinkitSettings,
    onOpenDetail: (SettingsRoute) -> Unit,
    onBackToHub: () -> Unit,
    onReconnect: () -> Unit,
    onDisconnect: () -> Unit,
    onRePair: () -> Unit,
    onForget: () -> Unit,
    onToggleClipboardSync: () -> Unit,
    onSetNotificationMirror: (Boolean) -> Unit,
    onSetAppearance: (AppearancePreference) -> Unit,
    onCheckUpdate: () -> Unit,
    onInstallUpdate: () -> Unit,
    onEnablePhoneControls: () -> Unit,
    onSetAccent: (String) -> Unit
) {
    when (route) {
        SettingsRoute.HUB -> SettingsHub(state = state, onOpenDetail = onOpenDetail)
        SettingsRoute.DEVICE -> DeviceDetail(
            state = state,
            onBack = onBackToHub,
            onReconnect = onReconnect,
            onDisconnect = onDisconnect,
            onRePair = onRePair,
            onForget = onForget
        )
        SettingsRoute.CLIPBOARD -> ClipboardDetail(state, onBackToHub, onToggleClipboardSync)
        SettingsRoute.NOTIFICATIONS -> NotificationsDetail(settings, onBackToHub, onSetNotificationMirror)
        SettingsRoute.PHONE -> PhoneDetail(state, onBackToHub, onEnablePhoneControls)
        SettingsRoute.APPEARANCE -> AppearanceDetail(settings, onBackToHub, onSetAppearance, onSetAccent)
        SettingsRoute.BACKGROUND -> BackgroundDetail(onBackToHub)
        SettingsRoute.UPDATES -> UpdatesDetail(state, onBackToHub, onCheckUpdate, onInstallUpdate)
        SettingsRoute.ABOUT -> AboutDetail(state, onBackToHub)
    }
}

/** The Settings hub: a short, scannable list of categories that drill in. */
@Composable
private fun SettingsHub(state: LinkitUiState, onOpenDetail: (SettingsRoute) -> Unit) {
    val accent = MaterialTheme.colorScheme.primary
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp)
            .padding(top = 8.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp)
    ) {
        LinkitLargeHeader(title = "Settings", subtitle = "Manage your Linkit connection and preferences.")

        SettingsGroupCard(label = "Connection") {
            HubRow(
                icon = Icons.Rounded.Devices,
                title = "Device",
                subtitle = if (state.isConnectedToMac) "Connected · ${state.trustedMac?.deviceName ?: "Mac"}" else "Paired, offline",
                accent = accent,
                onClick = { onOpenDetail(SettingsRoute.DEVICE) }
            )
        }

        SettingsGroupCard(label = "Features") {
            HubRow(Icons.Rounded.ContentPaste, "Clipboard", "Sync copied text between devices.", accent) { onOpenDetail(SettingsRoute.CLIPBOARD) }
            LinkitRowDivider()
            HubRow(Icons.Rounded.Notifications, "Notifications", "Mirror phone notifications to the Mac.", accent) { onOpenDetail(SettingsRoute.NOTIFICATIONS) }
            LinkitRowDivider()
            HubRow(Icons.Rounded.Call, "Phone", "Call control permissions and caller ID.", accent) { onOpenDetail(SettingsRoute.PHONE) }
        }

        SettingsGroupCard(label = "App") {
            HubRow(Icons.Rounded.Palette, "Appearance", "Accent color and light or dark theme.", accent) { onOpenDetail(SettingsRoute.APPEARANCE) }
            LinkitRowDivider()
            HubRow(Icons.Rounded.Bolt, "Background & battery", "Keep Linkit reachable while the screen is off.", accent) { onOpenDetail(SettingsRoute.BACKGROUND) }
            LinkitRowDivider()
            HubRow(Icons.Rounded.Download, "Updates", "Check for a newer Linkit build.", accent) { onOpenDetail(SettingsRoute.UPDATES) }
            LinkitRowDivider()
            HubRow(Icons.Rounded.Info, "About", "Version and source code.", accent) { onOpenDetail(SettingsRoute.ABOUT) }
        }
    }
}

/** A hub category row: icon tile, title, one-line summary, optional badge, chevron. */
@Composable
private fun HubRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    accent: Color,
    badge: Int = 0,
    onClick: () -> Unit
) {
    LinkitCardRow(icon = icon, title = title, subtitle = subtitle, accent = accent, onClick = onClick) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            if (badge > 0) {
                Box(
                    modifier = Modifier
                        .size(20.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.error),
                    contentAlignment = Alignment.Center
                ) {
                    Text("$badge", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onError)
                }
            }
            RowChevron()
        }
    }
}

/** Shared chrome for a Settings detail screen: back arrow, large header, content. */
@Composable
private fun SettingsDetailScaffold(
    title: String,
    subtitle: String,
    onBack: () -> Unit,
    content: @Composable ColumnScope.() -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp)
            .padding(bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp)
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            IconButton(onClick = onBack, modifier = Modifier.padding(top = 4.dp).size(36.dp)) {
                Icon(
                    imageVector = Icons.AutoMirrored.Rounded.ArrowBack,
                    contentDescription = "Back",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(22.dp)
                )
            }
            LinkitLargeHeader(title = title, subtitle = subtitle)
        }
        content()
    }
}

@Composable
private fun DeviceDetail(
    state: LinkitUiState,
    onBack: () -> Unit,
    onReconnect: () -> Unit,
    onDisconnect: () -> Unit,
    onRePair: () -> Unit,
    onForget: () -> Unit
) {
    val accent = MaterialTheme.colorScheme.primary
    SettingsDetailScaffold(
        title = "Device",
        subtitle = "Your paired Mac and connection.",
        onBack = onBack
    ) {
        SettingsGroupCard(label = "Connection") {
            val mac = state.trustedMac
            LinkitCardRow(
                icon = Icons.Rounded.Devices,
                title = mac?.deviceName ?: "Mac",
                subtitle = "${state.macIp}:${state.port}",
                accent = accent
            ) {
                Text(
                    if (state.isConnectedToMac) "Connected" else "Offline",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            LinkitRowDivider()
            if (state.isConnectedToMac) {
                LinkitCardRow(icon = Icons.Rounded.LinkOff, title = "Disconnect", accent = accent, onClick = onDisconnect) { RowChevron() }
            } else {
                LinkitCardRow(icon = Icons.Rounded.Refresh, title = "Reconnect", accent = accent, onClick = onReconnect) { RowChevron() }
            }
            LinkitRowDivider()
            LinkitCardRow(icon = Icons.Rounded.QrCodeScanner, title = "Pair with a different Mac", accent = accent, onClick = onRePair) { RowChevron() }
            LinkitRowDivider()
            LinkitCardRow(icon = Icons.Rounded.DeleteOutline, title = "Forget this Mac", accent = accent, onClick = onForget) {
                Text("Forget", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.error)
            }
        }
    }
}

@Composable
private fun ClipboardDetail(state: LinkitUiState, onBack: () -> Unit, onToggleClipboardSync: () -> Unit) {
    val accent = MaterialTheme.colorScheme.primary
    SettingsDetailScaffold(
        title = "Clipboard",
        subtitle = "Share copied text between your Mac and phone.",
        onBack = onBack
    ) {
        SettingsGroupCard(label = "Sync") {
            LinkitToggleRow(
                icon = Icons.Rounded.ContentPaste,
                title = "Sync clipboard to Mac",
                subtitle = "Text you copy is pushed to the Mac. Android → Mac only syncs while Linkit is open (an OS limit).",
                accent = accent,
                checked = state.clipboardSyncEnabled,
                enabled = state.isConnectedToMac || state.clipboardSyncEnabled,
                onCheckedChange = { onToggleClipboardSync() }
            )
        }
    }
}

@Composable
private fun NotificationsDetail(
    settings: LinkitSettings,
    onBack: () -> Unit,
    onSetNotificationMirror: (Boolean) -> Unit
) {
    val context = LocalContext.current
    val accent = MaterialTheme.colorScheme.primary
    var accessGranted by remember { mutableStateOf(NotificationAccess.isGranted(context)) }
    var showAccessHelp by remember { mutableStateOf(false) }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) accessGranted = NotificationAccess.isGranted(context)
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    SettingsDetailScaffold(
        title = "Notifications",
        subtitle = "Mirror phone notifications to your Mac.",
        onBack = onBack
    ) {
        SettingsGroupCard(label = "Mirroring") {
            LinkitToggleRow(
                icon = Icons.Rounded.Notifications,
                title = "Mirror phone notifications to Mac",
                subtitle = "Notifications that arrive on your phone briefly appear on the Mac. Needs notification access — a one-time Android setup.",
                accent = accent,
                checked = settings.notificationMirrorEnabled,
                onCheckedChange = { enabled ->
                    onSetNotificationMirror(enabled)
                    if (enabled && !accessGranted) showAccessHelp = true
                }
            )
            if (settings.notificationMirrorEnabled && !accessGranted) {
                LinkitRowDivider()
                LinkitCardRow(
                    icon = Icons.Rounded.WarningAmber,
                    title = "Set up notification access",
                    subtitle = "Mirroring won't work until access is granted.",
                    accent = accent,
                    onClick = { showAccessHelp = true }
                ) { RowChevron() }
            }
        }

        SettingsGroupCard(label = "System") {
            LinkitCardRow(
                icon = Icons.Rounded.Notifications,
                title = "Linkit notification settings",
                subtitle = "Open Android's notification settings for Linkit.",
                accent = accent,
                onClick = {
                    runCatching {
                        context.startActivity(
                            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                        )
                    }
                }
            ) { RowChevron() }
        }
    }

    if (showAccessHelp) {
        NotificationAccessDialog(
            onOpenSettings = {
                showAccessHelp = false
                runCatching { context.startActivity(NotificationAccess.settingsIntent()) }
            },
            onDismiss = { showAccessHelp = false }
        )
    }
}

@Composable
private fun PhoneDetail(state: LinkitUiState, onBack: () -> Unit, onEnablePhoneControls: () -> Unit) {
    SettingsDetailScaffold(
        title = "Phone",
        subtitle = "Place and control Android calls from your Mac.",
        onBack = onBack
    ) {
        PhoneControlsSection(status = state.phoneControlStatus, onEnable = onEnablePhoneControls)
    }
}

@Composable
private fun AppearanceDetail(
    settings: LinkitSettings,
    onBack: () -> Unit,
    onSetAppearance: (AppearancePreference) -> Unit,
    onSetAccent: (String) -> Unit
) {
    SettingsDetailScaffold(
        title = "Appearance",
        subtitle = "Make Linkit feel like yours.",
        onBack = onBack
    ) {
        SettingsGroupCard(label = "Accent color") {
            AccentColorPicker(currentHex = settings.accentColorHex, onSelect = onSetAccent)
        }
        SettingsGroupCard(label = "Theme") {
            Box(modifier = Modifier.padding(14.dp)) {
                AppearanceSelector(current = settings.appearance, onSelect = onSetAppearance)
            }
        }
    }
}

@Composable
private fun BackgroundDetail(onBack: () -> Unit) {
    val context = LocalContext.current
    val accent = MaterialTheme.colorScheme.primary
    val powerManager = context.getSystemService(PowerManager::class.java)
    var ignoringBattery by remember {
        mutableStateOf(powerManager?.isIgnoringBatteryOptimizations(context.packageName) == true)
    }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                ignoringBattery = powerManager?.isIgnoringBatteryOptimizations(context.packageName) == true
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    SettingsDetailScaffold(
        title = "Background & battery",
        subtitle = "Keep the Mac able to reach this phone while the screen is off.",
        onBack = onBack
    ) {
        SettingsGroupCard(label = "Background activity") {
            LinkitCardRow(
                icon = Icons.Rounded.Bolt,
                title = "Background activity",
                subtitle = if (ignoringBattery) {
                    "Allowed — Linkit keeps receiving while the screen is off."
                } else {
                    "Restricted — allow so the Mac can reach this phone in the background."
                },
                accent = accent,
                enabled = !ignoringBattery,
                onClick = {
                    runCatching {
                        @Suppress("BatteryLife")
                        context.startActivity(
                            Intent(
                                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:${context.packageName}")
                            )
                        )
                    }
                }
            ) { if (!ignoringBattery) RowChevron() }
        }
    }
}

@Composable
private fun UpdatesDetail(state: LinkitUiState, onBack: () -> Unit, onCheck: () -> Unit, onInstall: () -> Unit) {
    SettingsDetailScaffold(
        title = "Updates",
        subtitle = "Keep Linkit up to date.",
        onBack = onBack
    ) {
        UpdateSection(state = state, onCheck = onCheck, onInstall = onInstall)
    }
}

@Composable
private fun AboutDetail(state: LinkitUiState, onBack: () -> Unit) {
    SettingsDetailScaffold(
        title = "About",
        subtitle = "About Linkit.",
        onBack = onBack
    ) {
        AboutCard(version = state.currentAndroidVersion)
        LinkitFooter(version = "v${state.currentAndroidVersion}", accent = MaterialTheme.colorScheme.primary)
    }
}


@Composable
private fun NotificationAccessDialog(
    onOpenSettings: () -> Unit,
    onDismiss: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                "Allow notification access",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold
            )
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    "Android guards this permission, so it takes a few taps the first time:",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                NotificationAccessStep(1, "Tap “Open settings” below.")
                NotificationAccessStep(2, "Turn on “Allow notification access” for Linkit.")
                NotificationAccessStep(
                    3,
                    "If the switch is greyed out, tap the ⋮ menu (top-right) → “Allow restricted settings”, then turn it on."
                )
                Text(
                    "Linkit only forwards notification title and text to your paired Mac, over the local network.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.75f)
                )
            }
        },
        confirmButton = {
            TextButton(onClick = onOpenSettings) { Text("Open settings") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Later") }
        }
    )
}

@Composable
private fun NotificationAccessStep(number: Int, text: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(
            "$number.",
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.primary
        )
        Text(
            text,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurface
        )
    }
}

@Composable
private fun AppearanceSelector(
    current: AppearancePreference,
    onSelect: (AppearancePreference) -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        AppearancePreference.values().forEach { option ->
            val selected = option == current
            Box(
                modifier = Modifier
                    .weight(1f)
                    .heightIn(min = 44.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(
                        if (selected) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.surfaceVariant
                    )
                    .clickable { onSelect(option) },
                contentAlignment = Alignment.Center
            ) {
                Text(
                    option.label,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Medium,
                    color = if (selected) MaterialTheme.colorScheme.onPrimary
                    else MaterialTheme.colorScheme.onSurface
                )
            }
        }
    }
}

@Composable
private fun AccentColorPicker(currentHex: String, onSelect: (String) -> Unit) {
    Column(
        modifier = Modifier.padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        LinkitAccents.presets.chunked(5).forEach { rowPresets ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                rowPresets.forEach { preset ->
                    AccentSwatch(
                        color = LinkitAccents.color(preset.hex),
                        selected = LinkitAccents.normalize(preset.hex) == LinkitAccents.normalize(currentHex),
                        onClick = { onSelect(preset.hex) },
                        modifier = Modifier.weight(1f)
                    )
                }
                repeat(5 - rowPresets.size) { Spacer(modifier = Modifier.weight(1f)) }
            }
        }
        var customHex by remember(currentHex) { mutableStateOf(currentHex) }
        OutlinedTextField(
            value = customHex,
            onValueChange = { raw ->
                customHex = raw
                if (LinkitAccents.parse(raw) != null) onSelect(LinkitAccents.normalize(raw))
            },
            singleLine = true,
            label = { Text("Custom color (#RRGGBB)") },
            modifier = Modifier.fillMaxWidth()
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                LinkitAccents.nameFor(currentHex),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f)
            )
            if (LinkitAccents.normalize(currentHex) != LinkitAccents.DEFAULT_HEX) {
                TextButton(onClick = { onSelect(LinkitAccents.DEFAULT_HEX) }) {
                    Text("Reset", color = MaterialTheme.colorScheme.primary)
                }
            }
        }
    }
}

@Composable
private fun AccentSwatch(
    color: Color,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    Box(
        modifier = modifier
            .aspectRatio(1f)
            .clip(CircleShape)
            .background(color)
            .border(
                BorderStroke(if (selected) 3.dp else 1.dp, if (selected) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.outlineVariant),
                CircleShape
            )
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        if (selected) {
            Icon(
                imageVector = Icons.Rounded.Check,
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(18.dp)
            )
        }
    }
}

/** Routes an attention feature to the OS setting / action that re-enables it. */
private fun resolveFeatureAction(
    context: Context,
    feature: FeatureStatus,
    onReconnectNotificationListener: () -> Unit,
    onEnablePhoneControls: () -> Unit
) {
    when (feature.id) {
        AndroidFeatureStatus.ID_NOTIFICATION_MIRROR -> {
            onReconnectNotificationListener()
            if (!NotificationAccess.isGranted(context)) {
                runCatching { context.startActivity(NotificationAccess.settingsIntent()) }
            }
        }
        AndroidFeatureStatus.ID_PHONE_CONTROL -> onEnablePhoneControls()
        AndroidFeatureStatus.ID_BATTERY -> runCatching {
            @Suppress("BatteryLife")
            context.startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:${context.packageName}")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }
        AndroidFeatureStatus.ID_RECEIVER -> LinkitReceiverService.start(context)
        else -> Unit
    }
}

@Composable
private fun AboutCard(version: String) {
    val context = LocalContext.current
    val accent = MaterialTheme.colorScheme.primary
    SettingsGroupCard(label = "About") {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(14.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant),
                contentAlignment = Alignment.Center
            ) {
                Image(
                    painter = painterResource(R.mipmap.ic_launcher),
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize().clip(RoundedCornerShape(12.dp))
                )
            }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    "Linkit",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Text(
                    "A private, cloud-free link between your Mac and this phone. $version.",
                    fontSize = 12.sp,
                    lineHeight = 16.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
        LinkitRowDivider()
        LinkitCardRow(
            icon = Icons.Rounded.Link,
            title = "View on GitHub",
            accent = accent,
            onClick = {
                runCatching {
                    context.startActivity(
                        Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/kalki-kgp/Linkit"))
                    )
                }
            }
        ) { RowChevron() }
    }
}

@Composable
private fun LinkitTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    accent: Color = LinkitAccents.color(LinkitAccents.DEFAULT_HEX),
    content: @Composable () -> Unit
) {
    val base = if (darkTheme) {
        darkColorScheme(
            primary = LinkitPalette.AmberLight,
            onPrimary = LinkitPalette.InkDark,
            primaryContainer = LinkitPalette.AmberContainerDark,
            onPrimaryContainer = LinkitPalette.PaperWarm,
            background = LinkitPalette.InkDark,
            onBackground = LinkitPalette.PaperWarm,
            surface = LinkitPalette.SurfaceDark,
            onSurface = LinkitPalette.PaperWarm,
            surfaceVariant = LinkitPalette.SurfaceDarkHigh,
            onSurfaceVariant = LinkitPalette.MutedDark,
            tertiary = LinkitPalette.SageLight,
            onTertiary = LinkitPalette.InkDark,
            outline = LinkitPalette.OutlineDark,
            outlineVariant = LinkitPalette.OutlineDarkSoft,
            error = LinkitPalette.DangerLight,
            onError = LinkitPalette.InkDark,
            errorContainer = LinkitPalette.DangerContainerDark,
            onErrorContainer = LinkitPalette.PaperWarm
        )
    } else {
        lightColorScheme(
            primary = LinkitPalette.AmberDeep,
            onPrimary = Color.White,
            primaryContainer = LinkitPalette.AmberSoft,
            onPrimaryContainer = LinkitPalette.InkDark,
            background = LinkitPalette.PaperWarm,
            onBackground = LinkitPalette.InkDark,
            surface = Color(0xFFFFFFFF),
            onSurface = LinkitPalette.InkDark,
            surfaceVariant = LinkitPalette.SurfaceLight,
            onSurfaceVariant = LinkitPalette.MutedLight,
            tertiary = LinkitPalette.SageDeep,
            onTertiary = Color.White,
            outline = LinkitPalette.OutlineLight,
            outlineVariant = LinkitPalette.OutlineLightSoft,
            error = LinkitPalette.DangerDeep,
            onError = Color.White,
            errorContainer = LinkitPalette.DangerSoft,
            onErrorContainer = LinkitPalette.InkDark
        )
    }
    // Recolor the primary tint to the user's accent so every card, tile, toggle, and status
    // dot follows it — matching the Mac's accent-driven UI.
    val colors = base.copy(
        primary = accent,
        onPrimary = Color.White,
        primaryContainer = accent.copy(alpha = if (darkTheme) 0.28f else 0.18f)
    )
    MaterialTheme(
        colorScheme = colors,
        content = content
    )
}

private object LinkitPalette {
    // Light
    val PaperWarm = Color(0xFFFAF7F2)
    val InkDark = Color(0xFF1A1614)
    val SurfaceLight = Color(0xFFF1ECE3)
    val MutedLight = Color(0xFF6B6258)
    val OutlineLight = Color(0xFFB8AFA4)
    val OutlineLightSoft = Color(0xFFE4DDD2)
    val AmberDeep = Color(0xFFD16A1F)
    val AmberSoft = Color(0xFFFBE7D2)
    val SageDeep = Color(0xFF5B7A4D)
    val DangerDeep = Color(0xFFB83A3A)
    val DangerSoft = Color(0xFFF5DADA)

    // Dark
    val SurfaceDark = Color(0xFF221D1A)
    val SurfaceDarkHigh = Color(0xFF2D2724)
    val MutedDark = Color(0xFFA89E92)
    val OutlineDark = Color(0xFF4A413B)
    val OutlineDarkSoft = Color(0xFF3A322D)
    val AmberLight = Color(0xFFE89F4D)
    val AmberContainerDark = Color(0xFF6B3A12)
    val SageLight = Color(0xFF8FB180)
    val DangerLight = Color(0xFFE57878)
    val DangerContainerDark = Color(0xFF6B2A2A)
}

@Composable
private fun formatBytes(bytes: Long): String {
    return Formatter.formatFileSize(LocalContext.current, bytes)
}

private fun formatEta(seconds: Long): String {
    if (seconds <= 0) return "0s"
    val minutes = seconds / 60
    val rest = seconds % 60
    return if (minutes > 0) "${minutes}m ${rest}s" else "${rest}s"
}

private fun formatRelative(epochMillis: Long): String {
    val deltaSeconds = ((System.currentTimeMillis() - epochMillis) / 1000).coerceAtLeast(0)
    return when {
        deltaSeconds < 60 -> "just now"
        deltaSeconds < 3600 -> "${deltaSeconds / 60}m ago"
        deltaSeconds < 86_400 -> "${deltaSeconds / 3600}h ago"
        deltaSeconds < 7 * 86_400 -> "${deltaSeconds / 86_400}d ago"
        else -> java.text.SimpleDateFormat("MMM d", java.util.Locale.getDefault()).format(java.util.Date(epochMillis))
    }
}

