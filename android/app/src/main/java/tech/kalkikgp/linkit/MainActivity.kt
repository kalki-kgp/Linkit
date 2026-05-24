package tech.kalkikgp.linkit

import android.app.Application
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
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
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
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
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.AndroidViewModel
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
import kotlinx.coroutines.suspendCancellableCoroutine
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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        DebugTelemetry.install(applicationContext)
        consumeIncomingShareIntent(intent)
        requestNotificationPermissionIfNeeded()
        if (IdentityStore(applicationContext).trustedMac() != null) {
            LinkitReceiverService.start(applicationContext)
            linkitViewModel.discoverAndReconnect()
        }
        setContent {
            LinkitTheme {
                LinkitScreen(linkitViewModel)
            }
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            val granted = checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
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
        if (IdentityStore(applicationContext).trustedMac() != null &&
            !linkitViewModel.uiState.value.isConnectedToMac
        ) {
            linkitViewModel.discoverAndReconnect()
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
    val status: String = "Ready",
    val error: String? = null,
    val savedPath: String? = null,
    val tokenRejected: Boolean = false,
    val networkHint: String? = null,
    val clipboardSyncEnabled: Boolean = false
)

class LinkitViewModel(application: Application) : AndroidViewModel(application) {
    private val client = LinkitClient()
    private val identityStore = IdentityStore(application)
    private val discovery = BonjourDiscovery(application)
    private val history = TransferHistoryStore.get(application)
    val historyEntries: StateFlow<List<TransferHistoryEntry>> = history.entries

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
            }
        )
    )
    val uiState: StateFlow<LinkitUiState> = _uiState

    private var sendJob: Job? = null
    private var startedAtMillis: Long = 0
    private var clipboardListener: ClipboardManager.OnPrimaryClipChangedListener? = null
    private var lastClipboardText: String? = null

    init {
        viewModelScope.launch {
            AndroidDropEvents.events.collect { handleDropEvent(it) }
        }
        viewModelScope.launch {
            MacPresence.lastSeenMillis.collect { seenAt ->
                if (seenAt == null) return@collect
                if (_uiState.value.trustedMac == null) return@collect
                _uiState.update { state ->
                    if (state.isConnectedToMac && state.error == null) state
                    else state.copy(
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
            while (true) {
                delay(10_000)
                val state = _uiState.value
                if (!state.isConnectedToMac) continue
                if (state.isSending || state.isPairing) continue
                if (state.trustedMac == null) continue
                val lastSeen = MacPresence.lastSeenMillis.value ?: continue
                val ageMs = System.currentTimeMillis() - lastSeen
                if (ageMs > 90_000) {
                    DebugTelemetry.recordEvent("presence", "demoted to offline (last seen ${ageMs / 1000}s ago)")
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
    }

    override fun onCleared() {
        stopClipboardSync()
        discovery.stop()
        super.onCleared()
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
        val mac = _uiState.value.trustedMac ?: return
        _uiState.update { it.copy(status = "Connecting", androidReceiverStatus = "Connecting to Mac for drops", error = null, networkHint = null) }
        registerAndroidReceiver(mac)
    }

    private var reconnectJob: Job? = null

    fun discoverAndReconnect() {
        val mac = _uiState.value.trustedMac ?: return
        if (_uiState.value.isConnectedToMac || _uiState.value.isPairing) return
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
            val found = withTimeoutOrNull(5_000) {
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

            val target = if (found != null) {
                val updated = mac.copy(ip = found.ip, port = found.port)
                identityStore.saveTrustedMac(updated)
                _uiState.update {
                    it.copy(
                        trustedMac = updated,
                        macIp = updated.ip,
                        port = updated.port.toString(),
                        status = "Connecting"
                    )
                }
                DebugTelemetry.recordEvent("reconnect", "Bonjour resolved ${updated.ip}:${updated.port}")
                updated
            } else {
                _uiState.update { it.copy(status = "Trying last known address") }
                DebugTelemetry.recordEvent("reconnect", "Bonjour timeout, using last known ${mac.ip}:${mac.port}")
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
            _uiState.update { it.copy(clipboardSyncEnabled = false, status = "Clipboard sync off") }
            return
        }
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
        _uiState.update { it.copy(clipboardSyncEnabled = true, status = "Clipboard sync on", error = null) }
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

    private fun registerAndroidReceiver(mac: TrustedMac) {
        LinkitReceiverService.start(getApplication())
        viewModelScope.launch {
            runCatching {
                client.registerReceiver(
                    mac = mac,
                    identityStore = identityStore,
                    receivePort = AndroidDropReceiver.PORT,
                    batteryPercent = BatteryStatus.percent(getApplication())
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
 * UI · Linkit · macrostructure: Device-Hero + Action Grid + Activity
 *   genre: modern-minimal · theme: warm paper light / charcoal dark
 *   accent: amber #D16A1F (light) / #E89F4D (dark)
 *   motion: status-pulse, transfer-bar slide-up, button-press scale
 * ------------------------------------------------------------------------- */

@Composable
private fun LinkitScreen(viewModel: LinkitViewModel) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val history by viewModel.historyEntries.collectAsStateWithLifecycle()
    val context = LocalContext.current

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

    BackHandler(enabled = state.isSending) { viewModel.cancelActive() }

    Surface(
        modifier = Modifier.fillMaxSize(),
        color = MaterialTheme.colorScheme.background
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .systemBarsPadding()
        ) {
            if (state.trustedMac == null) {
                WelcomeScreen(
                    isPairing = state.isPairing,
                    error = state.error,
                    onPair = launchQrScanner
                )
            } else {
                HomeScreen(
                    state = state,
                    history = history,
                    onPickFile = { filePicker.launch(arrayOf("*/*")) },
                    onSendClipboard = viewModel::sendClipboardTextToMac,
                    onOpenLink = viewModel::openClipboardLinkOnMac,
                    onToggleClipboardSync = viewModel::toggleClipboardSync,
                    onReconnect = viewModel::discoverAndReconnect,
                    onRePair = launchQrScanner,
                    onForget = viewModel::forgetMac,
                    onClearHistory = viewModel::clearHistory
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
private fun HomeScreen(
    state: LinkitUiState,
    history: List<TransferHistoryEntry>,
    onPickFile: () -> Unit,
    onSendClipboard: () -> Unit,
    onOpenLink: () -> Unit,
    onToggleClipboardSync: () -> Unit,
    onReconnect: () -> Unit,
    onRePair: () -> Unit,
    onForget: () -> Unit,
    onClearHistory: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp)
            .padding(bottom = if (state.isSending) 120.dp else 24.dp)
    ) {
        TopBar(onRePair = onRePair, onForget = onForget)
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
        RecentActivity(entries = history, onClear = onClearHistory)
    }
}

@Composable
private fun TopBar(onRePair: () -> Unit, onForget: () -> Unit) {
    var menuOpen by remember { mutableStateOf(false) }
    val context = LocalContext.current
    var tapCount by remember { mutableStateOf(0) }
    var lastTapMillis by remember { mutableStateOf(0L) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 14.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
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
        Box {
            IconButton(onClick = { menuOpen = true }) {
                Text(
                    "⋮",
                    style = MaterialTheme.typography.titleLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            DropdownMenu(
                expanded = menuOpen,
                onDismissRequest = { menuOpen = false }
            ) {
                DropdownMenuItem(
                    text = { Text("Pair with a different Mac") },
                    onClick = { menuOpen = false; onRePair() }
                )
                DropdownMenuItem(
                    text = { Text("Forget this Mac") },
                    onClick = { menuOpen = false; onForget() }
                )
            }
        }
    }
}

@Composable
private fun DeviceCard(state: LinkitUiState, onReconnect: () -> Unit) {
    val mac = state.trustedMac ?: return
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(22.dp))
            .background(MaterialTheme.colorScheme.surface)
            .border(
                BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                RoundedCornerShape(22.dp)
            )
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            DeviceAvatar(name = mac.deviceName, connected = state.isConnectedToMac)
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Text(
                    mac.deviceName,
                    style = MaterialTheme.typography.titleLarge,
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
    Box(modifier = Modifier.size(56.dp)) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .clip(RoundedCornerShape(16.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant),
            contentAlignment = Alignment.Center
        ) {
            Text(
                name.firstInitial(),
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface
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
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            ActionTile(
                title = "Send file",
                subtitle = "Pick from this phone",
                enabled = enabled,
                onClick = onPickFile,
                modifier = Modifier.weight(1f)
            )
            ActionTile(
                title = "Send clipboard",
                subtitle = "Phone → Mac",
                enabled = enabled,
                onClick = onSendClipboard,
                modifier = Modifier.weight(1f)
            )
        }
        Row(
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            ActionTile(
                title = "Open link",
                subtitle = "Open URL on Mac",
                enabled = enabled,
                onClick = onOpenLink,
                modifier = Modifier.weight(1f)
            )
            ActionTile(
                title = "Mirror clipboard",
                subtitle = if (clipboardSyncOn) "On · tap to stop" else "Off · tap to enable",
                enabled = enabled || clipboardSyncOn,
                highlight = clipboardSyncOn,
                onClick = onToggleClipboardSync,
                modifier = Modifier.weight(1f)
            )
        }
    }
}

@Composable
private fun ActionTile(
    title: String,
    subtitle: String,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    highlight: Boolean = false
) {
    val container: Color
    val content: Color
    val borderColor: Color
    when {
        highlight -> {
            container = MaterialTheme.colorScheme.primary
            content = MaterialTheme.colorScheme.onPrimary
            borderColor = Color.Transparent
        }
        !enabled -> {
            container = MaterialTheme.colorScheme.surface.copy(alpha = 0.5f)
            content = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
            borderColor = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f)
        }
        else -> {
            container = MaterialTheme.colorScheme.surface
            content = MaterialTheme.colorScheme.onSurface
            borderColor = MaterialTheme.colorScheme.outlineVariant
        }
    }
    val base = modifier
        .heightIn(min = 112.dp)
        .clip(RoundedCornerShape(18.dp))
        .background(container)
        .border(BorderStroke(1.dp, borderColor), RoundedCornerShape(18.dp))
    val interactive = if (enabled) base.clickable(onClick = onClick) else base
    Column(
        modifier = interactive.padding(16.dp),
        verticalArrangement = Arrangement.SpaceBetween
    ) {
        Text(
            title,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            color = content,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
        Text(
            subtitle,
            style = MaterialTheme.typography.bodySmall,
            color = content.copy(alpha = if (highlight) 0.85f else 0.7f),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis
        )
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
                "Recent",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onBackground
            )
            if (entries.isNotEmpty()) {
                TextButton(onClick = onClear) {
                    Text(
                        "Clear",
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
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
    Row(
        modifier = Modifier
            .fillMaxWidth()
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
        Box(
            modifier = Modifier
                .size(20.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.error),
            contentAlignment = Alignment.Center
        ) {
            Text(
                "!",
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onError
            )
        }
        Text(
            message,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onErrorContainer,
            modifier = Modifier.weight(1f)
        )
    }
}

@Composable
private fun LinkitTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val colors = if (dark) {
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

private fun String.firstInitial(): String {
    val first = trim().firstOrNull { it.isLetterOrDigit() } ?: return "M"
    return first.uppercase()
}
