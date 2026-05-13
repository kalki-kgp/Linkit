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
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.io.IOException
import kotlin.math.max
import kotlin.math.roundToLong

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            LinkitTheme {
                LinkitScreen()
            }
        }
    }
}

data class LinkitUiState(
    val macIp: String = "",
    val port: String = "52718",
    val pairingToken: String = "",
    val pickedFiles: List<PickedFile> = emptyList(),
    val trustedMac: TrustedMac? = null,
    val isPairing: Boolean = false,
    val isSending: Boolean = false,
    val bytesSent: Long = 0,
    val totalBytes: Long = 0,
    val speedBytesPerSecond: Double = 0.0,
    val etaSeconds: Long? = null,
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
            status = if (identityStore.trustedMac() == null) "Pair with Mac" else "Ready"
        )
    )
    val uiState: StateFlow<LinkitUiState> = _uiState

    private var sendJob: Job? = null
    private var startedAtMillis: Long = 0

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
                    status = "Ready",
                    error = null,
                    savedPath = null,
                    bytesSent = 0,
                    totalBytes = files.sumOf { file -> file.size }
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
        identityStore.forgetTrustedMac()
        _uiState.update { it.copy(trustedMac = null, status = "Pair with Mac", savedPath = null) }
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
        viewModelScope.launch {
            _uiState.update { it.copy(isPairing = true, status = "Pairing", error = null, tokenRejected = false) }
            try {
                val mac = client.pair(
                    baseUrl = PrivateLanTarget.baseUrl(payload.ip, payload.port),
                    payload = payload,
                    identity = identityStore.identity()
                )
                identityStore.saveTrustedMac(mac)
                _uiState.update {
                    it.copy(
                        trustedMac = mac,
                        macIp = mac.ip,
                        port = mac.port.toString(),
                        isPairing = false,
                        status = "Paired",
                        error = null,
                        tokenRejected = false
                    )
                }
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
                    etaSeconds = null
                )
            }

            try {
                var completedBytes = 0L
                var lastSavedPath: String? = null
                for ((index, file) in files.withIndex()) {
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
                        etaSeconds = 0
                    )
                }
            } catch (cancelled: CancellationException) {
                _uiState.update {
                    it.copy(isSending = false, status = "Canceled", error = null, etaSeconds = null)
                }
            } catch (tokenError: TokenRejectedException) {
                _uiState.update {
                    it.copy(
                        isSending = false,
                        status = "Token rejected",
                        error = tokenError.message,
                        tokenRejected = true,
                        etaSeconds = null
                    )
                }
            } catch (http: LinkitHttpException) {
                _uiState.update {
                    it.copy(isSending = false, status = "Failed", error = http.message, etaSeconds = null)
                }
            } catch (io: IOException) {
                _uiState.update {
                    it.copy(isSending = false, status = "Network failed", error = io.message, etaSeconds = null)
                }
            } catch (error: Throwable) {
                _uiState.update {
                    it.copy(isSending = false, status = "Failed", error = error.message, etaSeconds = null)
                }
            } finally {
                sendJob = null
            }
        }
    }

    fun cancelActive() {
        sendJob?.cancel()
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
private fun LinkitScreen(viewModel: LinkitViewModel = viewModel()) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val context = LocalContext.current
    LaunchedEffect(Unit) {
        viewModel.consumeShareIntent((context as? ComponentActivity)?.intent)
    }
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

    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Text("Linkit", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold)

            state.trustedMac?.let { mac ->
                Text("Paired: ${mac.deviceName}", style = MaterialTheme.typography.bodyMedium)
            }

            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                OutlinedTextField(
                    value = state.macIp,
                    onValueChange = viewModel::setMacIp,
                    label = { Text("Mac IP") },
                    singleLine = true,
                    enabled = !state.isSending,
                    modifier = Modifier.weight(1f)
                )
                OutlinedTextField(
                    value = state.port,
                    onValueChange = viewModel::setPort,
                    label = { Text("Port") },
                    singleLine = true,
                    enabled = !state.isSending,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.weight(0.55f)
                )
            }

            OutlinedTextField(
                value = state.pairingToken,
                onValueChange = viewModel::setPairingToken,
                label = { Text("Pairing token") },
                singleLine = true,
                enabled = !state.isSending && !state.isPairing,
                isError = state.tokenRejected,
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.fillMaxWidth()
            )

            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedButton(
                    onClick = {
                        qrScanner.launch(
                            ScanOptions()
                                .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                                .setPrompt("Scan Linkit pairing QR")
                                .setBeepEnabled(false)
                        )
                    },
                    enabled = !state.isSending && !state.isPairing
                ) {
                    Text("Scan QR")
                }
                OutlinedButton(
                    onClick = viewModel::discoverMac,
                    enabled = !state.isSending && !state.isPairing
                ) {
                    Text("Discover")
                }
                Button(
                    onClick = viewModel::pairManual,
                    enabled = !state.isSending && !state.isPairing
                ) {
                    Text(if (state.isPairing) "Pairing" else "Pair")
                }
                if (state.trustedMac != null) {
                    OutlinedButton(onClick = viewModel::forgetMac, enabled = !state.isSending) {
                        Text("Forget")
                    }
                }
            }

            FileCard(state)

            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedButton(
                    onClick = { picker.launch(arrayOf("*/*")) },
                    enabled = !state.isSending
                ) {
                    Text("Pick file")
                }
                Button(
                    onClick = viewModel::send,
                    enabled = !state.isSending && state.pickedFiles.isNotEmpty() && state.trustedMac != null
                ) {
                    Text("Send")
                }
                if (state.isSending) {
                    OutlinedButton(onClick = viewModel::cancelActive) {
                        Text("Cancel")
                    }
                }
            }

            TransferStatus(state)
        }
    }
}

@Composable
private fun FileCard(state: LinkitUiState) {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            val file = state.pickedFiles.firstOrNull()
            Text(
                text = when {
                    state.pickedFiles.isEmpty() -> "No file selected"
                    state.pickedFiles.size == 1 -> file?.name.orEmpty()
                    else -> "${state.pickedFiles.size} files selected"
                },
                style = MaterialTheme.typography.titleMedium,
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
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

@Composable
private fun TransferStatus(state: LinkitUiState) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
        Text(state.status, style = MaterialTheme.typography.titleMedium)

        if (state.isSending || state.bytesSent > 0) {
            val progress = if (state.totalBytes > 0) {
                (state.bytesSent.toFloat() / state.totalBytes.toFloat()).coerceIn(0f, 1f)
            } else {
                0f
            }
            LinearProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxWidth())
            Text(
                text = buildString {
                    append("${formatBytes(state.bytesSent)} / ${formatBytes(state.totalBytes)}")
                    if (state.speedBytesPerSecond > 0) {
                        append("  ${formatBytes(state.speedBytesPerSecond.roundToLong())}/s")
                    }
                    state.etaSeconds?.let { append("  ${formatEta(it)}") }
                },
                style = MaterialTheme.typography.bodyMedium
            )
        }

        state.savedPath?.let {
            Text(
                text = it,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.primary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
        }

        state.error?.let {
            Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
        }

        Spacer(modifier = Modifier.height(1.dp))
    }
}

@Composable
private fun LinkitTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = lightColorScheme(
            primary = androidx.compose.ui.graphics.Color(0xFF2563EB),
            secondary = androidx.compose.ui.graphics.Color(0xFF0F766E),
            surfaceVariant = androidx.compose.ui.graphics.Color(0xFFEFF3F8)
        ),
        content = content
    )
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
