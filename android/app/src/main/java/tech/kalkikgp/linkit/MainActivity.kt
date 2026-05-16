package tech.kalkikgp.linkit

import android.app.Application
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
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.io.IOException
import java.time.Instant
import kotlin.math.max
import kotlin.math.roundToLong

class MainActivity : ComponentActivity() {
    private val linkitViewModel: LinkitViewModel by viewModels()

    private val notificationPermission = registerForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestPermission()
    ) { /* user choice respected; service still runs */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        linkitViewModel.consumeShareIntent(intent)
        requestNotificationPermissionIfNeeded()
        if (IdentityStore(applicationContext).trustedMac() != null) {
            LinkitReceiverService.start(applicationContext)
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
        linkitViewModel.consumeShareIntent(intent)
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
    val tokenRejected: Boolean = false
)

class LinkitViewModel(application: Application) : AndroidViewModel(application) {
    private val client = LinkitClient()
    private val identityStore = IdentityStore(application)
    private val discovery = BonjourDiscovery(application)
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

    init {
        identityStore.trustedMac()?.let(::registerAndroidReceiver)
    }

    override fun onCleared() {
        discovery.stop()
        super.onCleared()
    }

    fun setMacIp(value: String) {
        _uiState.update { it.copy(macIp = value, error = null, tokenRejected = false) }
    }

    fun setPort(value: String) {
        _uiState.update { it.copy(port = value.filter(Char::isDigit).take(5), error = null) }
    }

    fun setPairingToken(value: String) {
        _uiState.update { it.copy(pairingToken = value.trim(), error = null, tokenRejected = false) }
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
        val state = _uiState.value
        val ip = PrivateLanTarget.validateIp(state.macIp).getOrElse { error ->
            _uiState.update { it.copy(error = error.message) }
            return
        }
        val port = PrivateLanTarget.validatePort(state.port).getOrElse { error ->
            _uiState.update { it.copy(error = error.message) }
            return
        }
        val token = state.pairingToken.trim()
        if (token.isEmpty()) {
            _uiState.update { it.copy(error = "Pairing token is required", tokenRejected = true) }
            return
        }
        pair(
            MacPairingPayload(
                deviceId = "",
                deviceName = "Linkit Mac",
                publicKey = "",
                ip = ip,
                port = port,
                pairingToken = token
            )
        )
    }

    fun pairFromQr(raw: String) {
        runCatching { PairingPayloadParser.parse(raw) }
            .onSuccess { payload ->
                _uiState.update {
                    it.copy(
                        macIp = payload.ip,
                        port = payload.port.toString(),
                        pairingToken = payload.pairingToken,
                        error = null
                    )
                }
                pair(payload)
            }
            .onFailure { error ->
                _uiState.update { it.copy(error = error.message ?: "Invalid Linkit QR") }
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
            _uiState.update {
                it.copy(
                    trustedMac = null,
                    isConnectedToMac = false,
                    status = "Pair with Mac",
                    savedPath = null,
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
        _uiState.update { it.copy(status = "Connecting", androidReceiverStatus = "Connecting to Mac for drops", error = null) }
        registerAndroidReceiver(mac)
    }

    fun discoverMac() {
        _uiState.update { it.copy(status = "Discovering", error = null) }
        discovery.start(
            onFound = { mac ->
                _uiState.update {
                    it.copy(macIp = mac.ip, port = mac.port.toString(), status = "Found ${mac.name}", error = null)
                }
            },
            onError = { message ->
                _uiState.update { it.copy(status = "Discovery failed", error = message) }
            }
        )
    }

    private fun pair(payload: MacPairingPayload) {
        if (_uiState.value.isPairing) return
        val ip = PrivateLanTarget.validateIp(payload.ip).getOrElse { error ->
            _uiState.update { it.copy(status = "Pairing failed", error = error.message) }
            return
        }
        val port = PrivateLanTarget.validatePort(payload.port.toString()).getOrElse { error ->
            _uiState.update { it.copy(status = "Pairing failed", error = error.message) }
            return
        }
        val expiresAt = payload.pairingTokenExpiresAt?.let { raw ->
            runCatching { Instant.parse(raw) }.getOrElse {
                _uiState.update { it.copy(status = "Pairing failed", error = "Pairing QR has an invalid expiry") }
                return
            }
        }
        if (expiresAt != null && Instant.now().isAfter(expiresAt)) {
            _uiState.update {
                it.copy(status = "Pairing expired", error = "Refresh the QR on your Mac and scan again", tokenRejected = true)
            }
            return
        }
        val validatedPayload = payload.copy(ip = ip, port = port)

        viewModelScope.launch {
            _uiState.update { it.copy(isPairing = true, status = "Pairing", error = null, tokenRejected = false) }
            try {
                val mac = client.pair(
                    baseUrl = PrivateLanTarget.baseUrl(validatedPayload.ip, validatedPayload.port),
                    payload = validatedPayload,
                    identity = identityStore.identity()
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
                        tokenRejected = false
                    )
                }
                registerAndroidReceiver(mac)
            } catch (http: LinkitHttpException) {
                _uiState.update {
                    it.copy(isPairing = false, status = "Pairing failed", error = http.message, tokenRejected = http.statusCode == 401)
                }
            } catch (error: Throwable) {
                _uiState.update {
                    it.copy(isPairing = false, status = "Pairing failed", error = error.message)
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
                    val result = client.sendFile(
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
                    completedBytes += result.bytesSent
                    lastSavedPath = result.savedPath
                }

                _uiState.update {
                    it.copy(
                        isSending = false,
                        status = "Complete",
                        savedPath = lastSavedPath,
                        bytesSent = completedBytes,
                        totalBytes = completedBytes,
                        error = null,
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
                    it.copy(isSending = false, status = "Network failed", error = io.message, etaSeconds = null, currentFileName = null)
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

    private fun registerAndroidReceiver(mac: TrustedMac) {
        LinkitReceiverService.start(getApplication())
        viewModelScope.launch {
            runCatching {
                client.registerReceiver(mac, identityStore, AndroidDropReceiver.PORT)
            }.onSuccess {
                _uiState.update { state ->
                    state.copy(
                        isConnectedToMac = true,
                        status = if (state.isSending || state.isPairing) state.status else "Connected",
                        androidReceiverStatus = "Mac drops enabled"
                    )
                }
            }.onFailure { error ->
                _uiState.update { state ->
                    state.copy(
                        isConnectedToMac = false,
                        status = if (state.trustedMac == null) "Pair with Mac" else "Paired, offline",
                        androidReceiverStatus = "Open Linkit on Mac to connect: ${error.message}"
                    )
                }
            }
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

@Composable
private fun LinkitScreen(viewModel: LinkitViewModel) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty()) {
            runCatching {
                uris.forEach { uri ->
                    context.contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION
                    )
                }
            }
            viewModel.pick(uris)
        }
    }
    val qrScanner = rememberLauncherForActivityResult(ScanContract()) { result ->
        result.contents?.let(viewModel::pairFromQr)
    }

    BackHandler(enabled = state.isSending) {
        viewModel.cancelActive()
    }

    Surface(modifier = Modifier.fillMaxSize(), color = WorkbenchColors.Ink) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Header(state)

            Section("Target") {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                    LinkitTextField(
                        value = state.macIp,
                        onValueChange = viewModel::setMacIp,
                        label = "Mac IP",
                        enabled = !state.isSending,
                        modifier = Modifier.weight(1f)
                    )
                    LinkitTextField(
                        value = state.port,
                        onValueChange = viewModel::setPort,
                        label = "Port",
                        enabled = !state.isSending,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        modifier = Modifier.weight(0.55f)
                    )
                }
                LinkitTextField(
                    value = state.pairingToken,
                    onValueChange = viewModel::setPairingToken,
                    label = "Pairing token",
                    enabled = !state.isSending && !state.isPairing,
                    isError = state.tokenRejected,
                    visualTransformation = PasswordVisualTransformation(),
                    modifier = Modifier.fillMaxWidth()
                )
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                    SecondaryButton(
                        text = "Scan QR",
                        onClick = {
                            qrScanner.launch(
                                ScanOptions()
                                    .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                                    .setPrompt("Scan Linkit pairing QR")
                                    .setBeepEnabled(false)
                                    .setCaptureActivity(PortraitCaptureActivity::class.java)
                                    .setOrientationLocked(false)
                            )
                        },
                        enabled = !state.isSending && !state.isPairing,
                        modifier = Modifier.weight(1f)
                    )
                    SecondaryButton(
                        text = "Discover",
                        onClick = viewModel::discoverMac,
                        enabled = !state.isSending && !state.isPairing,
                        modifier = Modifier.weight(1f)
                    )
                }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                    PrimaryButton(
                        text = if (state.isPairing) "Pairing" else "Pair",
                        onClick = viewModel::pairManual,
                        enabled = !state.isSending && !state.isPairing,
                        modifier = Modifier.weight(1f)
                    )
                    if (state.trustedMac != null) {
                        SecondaryButton(
                            text = if (state.isConnectedToMac) "Disconnect" else "Connect",
                            onClick = if (state.isConnectedToMac) viewModel::disconnectMac else viewModel::connectMac,
                            enabled = !state.isSending && !state.isPairing,
                            modifier = Modifier.weight(1f)
                        )
                        SecondaryButton(
                            text = "Forget",
                            onClick = viewModel::forgetMac,
                            enabled = !state.isSending,
                            modifier = Modifier.weight(1f)
                        )
                    }
                }
            }

            Section("Payload") {
                FileCard(state)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                    SecondaryButton(
                        text = "Pick file",
                        onClick = { picker.launch(arrayOf("*/*")) },
                        enabled = !state.isSending,
                        modifier = Modifier.weight(1f)
                    )
                    PrimaryButton(
                        text = "Send",
                        onClick = viewModel::send,
                        enabled = !state.isSending && state.pickedFiles.isNotEmpty() && state.isConnectedToMac,
                        modifier = Modifier.weight(1f)
                    )
                    if (state.isSending) {
                        SecondaryButton(
                            text = "Cancel",
                            onClick = viewModel::cancelActive,
                            modifier = Modifier.weight(1f)
                        )
                    }
                }
            }

            TransferStatus(state)
        }
    }
}

@Composable
private fun Header(state: LinkitUiState) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
            Box(
                modifier = Modifier
                    .size(42.dp)
                    .clip(RoundedCornerShape(7.dp))
                    .background(WorkbenchColors.PanelLift)
            ) {
                Image(
                    painter = painterResource(R.mipmap.ic_launcher),
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize()
                )
            }
            Column(modifier = Modifier.weight(1f)) {
                Text("Linkit", color = WorkbenchColors.Paper, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Black)
                Text("Local signed drop", color = WorkbenchColors.Muted, style = MaterialTheme.typography.bodyMedium)
            }
            StatusPill(state)
        }
        state.trustedMac?.let { mac ->
            val connectionLabel = if (state.isConnectedToMac) "Connected to" else "Paired with"
            Text(
                text = "$connectionLabel ${mac.deviceName}",
                color = if (state.isConnectedToMac) WorkbenchColors.Signal else WorkbenchColors.Muted,
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
        Text(
            text = state.androidReceiverStatus,
            color = WorkbenchColors.Muted,
            style = MaterialTheme.typography.bodySmall,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis
        )
        state.lastAndroidDropPath?.let {
            Text(
                text = it,
                color = WorkbenchColors.Signal,
                style = MaterialTheme.typography.bodySmall,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

@Composable
private fun StatusPill(state: LinkitUiState) {
    val color = when {
        state.error != null -> WorkbenchColors.Error
        state.isSending || state.isPairing -> WorkbenchColors.Warning
        state.isConnectedToMac -> WorkbenchColors.Signal
        state.trustedMac != null -> WorkbenchColors.Muted
        else -> WorkbenchColors.Muted
    }
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(999.dp))
            .border(1.dp, color, RoundedCornerShape(999.dp))
            .padding(horizontal = 10.dp, vertical = 7.dp),
        horizontalArrangement = Arrangement.spacedBy(7.dp)
    ) {
        Box(modifier = Modifier.size(8.dp).clip(RoundedCornerShape(999.dp)).background(color))
        Text(state.status, color = color, style = MaterialTheme.typography.labelMedium, maxLines = 1)
    }
}

@Composable
private fun Section(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
        Text(
            title.uppercase(),
            color = WorkbenchColors.Muted,
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.Bold
        )
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(8.dp))
                .background(WorkbenchColors.Panel)
                .border(1.dp, WorkbenchColors.Line, RoundedCornerShape(8.dp))
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
            content = content
        )
    }
}

@Composable
private fun LinkitTextField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    isError: Boolean = false,
    visualTransformation: androidx.compose.ui.text.input.VisualTransformation = androidx.compose.ui.text.input.VisualTransformation.None,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = true,
        enabled = enabled,
        isError = isError,
        visualTransformation = visualTransformation,
        keyboardOptions = keyboardOptions,
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = WorkbenchColors.Paper,
            unfocusedTextColor = WorkbenchColors.Paper,
            focusedLabelColor = WorkbenchColors.Signal,
            unfocusedLabelColor = WorkbenchColors.Muted,
            focusedBorderColor = WorkbenchColors.Signal,
            unfocusedBorderColor = WorkbenchColors.Line,
            cursorColor = WorkbenchColors.Signal,
            disabledTextColor = WorkbenchColors.Muted,
            disabledLabelColor = WorkbenchColors.Muted
        ),
        shape = RoundedCornerShape(7.dp),
        modifier = modifier
    )
}

@Composable
private fun PrimaryButton(text: String, onClick: () -> Unit, enabled: Boolean = true, modifier: Modifier = Modifier) {
    Button(
        onClick = onClick,
        enabled = enabled,
        shape = RoundedCornerShape(7.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = WorkbenchColors.Signal,
            contentColor = WorkbenchColors.Ink,
            disabledContainerColor = WorkbenchColors.Line,
            disabledContentColor = WorkbenchColors.Muted
        ),
        modifier = modifier
    ) {
        Text(text, maxLines = 1)
    }
}

@Composable
private fun SecondaryButton(text: String, onClick: () -> Unit, enabled: Boolean = true, modifier: Modifier = Modifier) {
    OutlinedButton(
        onClick = onClick,
        enabled = enabled,
        shape = RoundedCornerShape(7.dp),
        colors = ButtonDefaults.outlinedButtonColors(
            contentColor = WorkbenchColors.Paper,
            disabledContentColor = WorkbenchColors.Muted
        ),
        modifier = modifier
    ) {
        Text(text, maxLines = 1)
    }
}

@Composable
private fun FileCard(state: LinkitUiState) {
    Card(
        shape = RoundedCornerShape(7.dp),
        colors = CardDefaults.cardColors(containerColor = WorkbenchColors.PanelLift),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            val file = state.pickedFiles.firstOrNull()
            Text(
                text = when {
                    state.pickedFiles.isEmpty() -> "No file selected"
                    state.pickedFiles.size == 1 -> file?.name.orEmpty()
                    else -> "${state.pickedFiles.size} files selected"
                },
                color = WorkbenchColors.Paper,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            if (file != null) {
                Text(
                    text = if (state.pickedFiles.size == 1) {
                        "${formatBytes(file.size)} - ${file.mimeType}"
                    } else {
                        formatBytes(state.pickedFiles.sumOf { it.size })
                    },
                    style = MaterialTheme.typography.bodyMedium,
                    color = WorkbenchColors.Muted
                )
                if (state.pickedFiles.size > 1) {
                    Text(
                        text = state.pickedFiles.take(3).joinToString("  /  ") { it.name },
                        style = MaterialTheme.typography.bodySmall,
                        color = WorkbenchColors.Muted,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
        }
    }
}

@Composable
private fun TransferStatus(state: LinkitUiState) {
    Column(
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(WorkbenchColors.Panel)
            .border(1.dp, WorkbenchColors.Line, RoundedCornerShape(8.dp))
            .padding(12.dp)
    ) {
        Text(state.status, color = WorkbenchColors.Paper, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)

        if (state.isSending || state.bytesSent > 0) {
            state.currentFileName?.let {
                Text(
                    text = it,
                    color = WorkbenchColors.Muted,
                    style = MaterialTheme.typography.bodyMedium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            val progress = if (state.totalBytes > 0) {
                (state.bytesSent.toFloat() / state.totalBytes.toFloat()).coerceIn(0f, 1f)
            } else {
                0f
            }
            LinearProgressIndicator(
                progress = { progress },
                color = WorkbenchColors.Signal,
                trackColor = WorkbenchColors.Line,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(8.dp)
                    .clip(RoundedCornerShape(999.dp))
            )
            Text(
                text = buildString {
                    append("${formatBytes(state.bytesSent)} / ${formatBytes(state.totalBytes)}")
                    if (state.speedBytesPerSecond > 0) {
                        append("  ${formatBytes(state.speedBytesPerSecond.roundToLong())}/s")
                    }
                    state.etaSeconds?.let { append("  ${formatEta(it)}") }
                },
                color = WorkbenchColors.Muted,
                style = MaterialTheme.typography.bodyMedium
            )
        }

        state.savedPath?.let {
            Text(
                text = it,
                style = MaterialTheme.typography.bodySmall,
                color = WorkbenchColors.Signal,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
        }

        state.error?.let {
            Text(it, color = WorkbenchColors.Error, style = MaterialTheme.typography.bodyMedium)
        }

        Spacer(modifier = Modifier.height(1.dp))
    }
}

@Composable
private fun LinkitTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = lightColorScheme(
            primary = WorkbenchColors.Signal,
            secondary = WorkbenchColors.Warning,
            background = WorkbenchColors.Ink,
            surface = WorkbenchColors.Panel,
            surfaceVariant = WorkbenchColors.PanelLift,
            error = WorkbenchColors.Error
        ),
        content = content
    )
}

private object WorkbenchColors {
    val Ink = Color(0xFF101214)
    val Panel = Color(0xFF171A1D)
    val PanelLift = Color(0xFF20252A)
    val Line = Color(0xFF343A40)
    val Paper = Color(0xFFEFF3F0)
    val Muted = Color(0xFF9BA7A1)
    val Signal = Color(0xFF79F2B0)
    val Warning = Color(0xFFF2C879)
    val Error = Color(0xFFFF6B6B)
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
