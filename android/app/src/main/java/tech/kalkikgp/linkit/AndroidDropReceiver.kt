package tech.kalkikgp.linkit

import android.content.ContentValues
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Base64
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.math.BigInteger
import java.net.ServerSocket
import java.net.Socket
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.min

private const val RECEIVER_TAG = "Linkit"
private const val SESSION_TTL_MILLIS = 10 * 60 * 1000L

data class AndroidDropEvent(
    val status: String,
    val savedPath: String? = null,
    val error: String? = null
)

class AndroidDropReceiver(
    private val context: Context,
    private val identityStore: IdentityStore,
    private val onEvent: (AndroidDropEvent) -> Unit
) {
    private val history = TransferHistoryStore.get(context)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val sessions = ConcurrentHashMap<String, DropSession>()
    private val nonceCache = AndroidNonceCache()
    private val random = SecureRandom()
    @Volatile private var serverSocket: ServerSocket? = null

    fun start() {
        if (serverSocket != null) return
        scope.launch {
            try {
                val socket = ServerSocket(PORT).also {
                    it.reuseAddress = true
                    serverSocket = it
                }
                onEvent(AndroidDropEvent("Mac drops enabled on port $PORT"))
                while (isActive) {
                    val client = socket.accept()
                    client.soTimeout = 60_000
                    launch { handleClient(client) }
                }
            } catch (closed: IOException) {
                if (isActive) {
                    Log.w(RECEIVER_TAG, "Android receiver stopped", closed)
                    onEvent(AndroidDropEvent("Mac drop receiver failed", error = closed.message))
                }
            }
        }
    }

    fun stop() {
        runCatching { serverSocket?.close() }
        serverSocket = null
        scope.cancel()
    }

    private fun handleClient(socket: Socket) {
        socket.use {
            try {
                val request = readRequest(socket.getInputStream())
                val response = route(request)
                writeResponse(socket.getOutputStream(), response)
            } catch (failure: DropHttpFailure) {
                writeResponse(socket.getOutputStream(), jsonResponse(failure.status, failure.error, failure.message))
            } catch (error: Throwable) {
                Log.e(RECEIVER_TAG, "Android drop request failed", error)
                writeResponse(socket.getOutputStream(), jsonResponse(500, "internal_error", "Android receiver error"))
            }
        }
    }

    private fun route(request: DropRequest): DropResponse {
        sweepExpiredSessions()
        if (request.method == "GET" && request.path == "/v1/info") {
            val identity = identityStore.identity()
            return jsonResponse(
                200,
                JSONObject()
                    .put("protocolVersion", 1)
                    .put("deviceId", identity.deviceId)
                    .put("deviceName", identity.deviceName)
                    .put("platform", "android")
                    .put("port", PORT)
                    .put("publicKey", identity.publicKey)
                    .put("capabilities", JSONArray().put("receive_files").put("stream_sha256").put("signed_controls").put("device_status").put("text_actions").put("clipboard_text").put("open_url"))
            )
        }

        if (request.method == "GET" && request.path == "/v1/devices/self/status") {
            verifySigned(request, ByteArray(0))
            return jsonResponse(200, deviceStatusJson())
        }

        if (request.method == "POST" && request.path == "/v1/actions") {
            val body = readBody(request, maxBytes = 256 * 1024)
            verifySigned(request, body)
            val json = JSONObject(String(body, Charsets.UTF_8))
            return jsonResponse(200, handleAction(json))
        }

        if (request.method == "POST" && request.path == "/v1/transfers") {
            val body = readBody(request, maxBytes = 64 * 1024)
            val deviceId = verifySigned(request, body)
            val json = JSONObject(String(body, Charsets.UTF_8))
            return jsonResponse(201, createTransfer(json, deviceId))
        }

        val parts = request.path.trim('/').split("/")
        if (parts.size == 5 && request.method == "PUT" && parts[0] == "v1" && parts[1] == "transfers" && parts[3] == "files") {
            return jsonResponse(200, uploadFile(request, parts[2], parts[4].toIntOrNull() ?: -1))
        }

        if (parts.size == 4 && request.method == "POST" && parts[0] == "v1" && parts[1] == "transfers" && parts[3] == "finalize") {
            val body = readBody(request, maxBytes = 16 * 1024)
            val deviceId = verifySigned(request, body)
            val json = JSONObject(String(body, Charsets.UTF_8))
            return jsonResponse(200, finalizeTransfer(parts[2], json, deviceId))
        }

        if (parts.size == 3 && request.method == "DELETE" && parts[0] == "v1" && parts[1] == "transfers") {
            val deviceId = verifySigned(request, ByteArray(0))
            val session = sessions[parts[2]] ?: throw DropHttpFailure(404, "not_found", "Transfer was not found")
            ensureOwner(session, deviceId)
            session.status = "canceled"
            session.error = "canceled"
            session.tempFile.delete()
            recordHistory(session)
            onEvent(AndroidDropEvent("Mac drop canceled"))
            return jsonResponse(200, statusJson(session))
        }

        throw DropHttpFailure(404, "not_found", "Endpoint was not found")
    }

    private fun handleAction(json: JSONObject): JSONObject {
        val type = json.getString("type").lowercase()
        val text = json.getString("text")
        if (text.isEmpty() || text.toByteArray(Charsets.UTF_8).size > 128 * 1024) {
            throw DropHttpFailure(400, "invalid_action_text", "Action text must be 1 byte to 128 KB")
        }
        when (type) {
            "clipboard", "text" -> {
                val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipboard.setPrimaryClip(ClipData.newPlainText("Linkit", text))
                onEvent(AndroidDropEvent(if (type == "clipboard") "Clipboard received from Mac" else "Text received from Mac"))
            }
            "open_url" -> {
                val uri = Uri.parse(text)
                val scheme = uri.scheme?.lowercase()
                if (scheme != "http" && scheme != "https") {
                    throw DropHttpFailure(400, "invalid_url", "Only http and https URLs can be opened")
                }
                val intent = Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
                onEvent(AndroidDropEvent("Opened link from Mac"))
            }
            else -> throw DropHttpFailure(400, "unsupported_action", "Action type is not supported")
        }
        return JSONObject().put("status", "ok").put("type", type)
    }

    private fun createTransfer(json: JSONObject, deviceId: String): JSONObject {
        val trusted = trustedMac()
        if (trusted.deviceId != deviceId) {
            throw DropHttpFailure(401, "unknown_device", "Device is not paired")
        }
        val files = json.getJSONArray("files")
        if (files.length() != 1) {
            throw DropHttpFailure(400, "single_file_only", "Android receiver accepts one file per transfer")
        }
        val file = files.getJSONObject(0)
        val id = "tr_" + token(18)
        val size = file.getLong("size")
        if (size < 0) throw DropHttpFailure(400, "invalid_size", "File size must be non-negative")
        val safeName = sanitizeFilename(file.getString("name"))
        val uploadToken = token(32)
        val tempDir = File(context.cacheDir, "linkit-drop-tmp").apply { mkdirs() }
        val session = DropSession(
            id = id,
            clientDeviceId = deviceId,
            originalName = file.getString("name"),
            safeName = safeName,
            expectedSize = size,
            mimeType = file.optString("mimeType").takeIf { it.isNotBlank() && it != "null" },
            clientSha256 = file.optString("clientSha256").lowercase().takeIf { it.matches(Regex("[0-9a-f]{64}")) },
            uploadToken = uploadToken,
            tempFile = File(tempDir, "$id-0.part")
        )
        sessions[id] = session
        onEvent(AndroidDropEvent("Ready to receive ${session.safeName}"))
        return JSONObject()
            .put("transferId", id)
            .put("status", session.status)
            .put("clientDeviceId", deviceId)
            .put("files", JSONArray().put(createdFileJson(session)))
            .put("uploadUrl", "/v1/transfers/$id/files/0")
            .put("finalizeUrl", "/v1/transfers/$id/finalize")
            .put("statusUrl", "/v1/transfers/$id")
            .put("uploadToken", uploadToken)
            .put("uploadTokenExpiresAt", "")
            .put("expiresAt", "")
    }

    private fun uploadFile(request: DropRequest, transferId: String, index: Int): JSONObject {
        val session = sessions[transferId] ?: throw DropHttpFailure(404, "not_found", "Transfer was not found")
        ensureLive(session)
        if (index != 0) throw DropHttpFailure(404, "not_found", "File index was not found")
        if (request.contentLength != session.expectedSize) {
            throw DropHttpFailure(400, "content_length_mismatch", "Content-Length must match transfer size")
        }
        val uploadToken = request.headers["x-linkit-upload-token"]
            ?: throw DropHttpFailure(401, "upload_token_rejected", "Upload token was not accepted")
        if (uploadToken != session.uploadToken) {
            throw DropHttpFailure(401, "upload_token_rejected", "Upload token was not accepted")
        }
        val signedDeviceId = verifyUploadSignature(request, transferId, index, uploadToken)
        if (request.headers["x-linkit-client-device-id"] != signedDeviceId) {
            throw DropHttpFailure(401, "client_device_mismatch", "Upload client device id does not match the signature")
        }
        if (signedDeviceId != session.clientDeviceId) {
            throw DropHttpFailure(401, "client_device_mismatch", "Upload token is not valid for this client device")
        }
        if (session.uploadTokenConsumed) {
            throw DropHttpFailure(409, "upload_token_used", "Upload token was already used")
        }

        session.uploadTokenConsumed = true
        session.status = "uploading"
        val digest = MessageDigest.getInstance("SHA-256")
        var received = 0L
        try {
            FileOutputStream(session.tempFile).use { output ->
                val buffer = ByteArray(1024 * 1024)
                while (received < session.expectedSize) {
                    if (session.status == "canceled") {
                        throw DropHttpFailure(409, "canceled", "Transfer was canceled")
                    }
                    val read = request.input.read(buffer, 0, min(buffer.size.toLong(), session.expectedSize - received).toInt())
                    if (read == -1) {
                        throw DropHttpFailure(400, "connection_closed", "Client disconnected before upload completed")
                    }
                    output.write(buffer, 0, read)
                    digest.update(buffer, 0, read)
                    received += read
                }
            }
            session.bytesReceived = received
            session.serverSha256 = digest.digest().toHex()
            session.status = "uploaded"
            onEvent(AndroidDropEvent("Received ${session.safeName}"))
            return JSONObject()
                .put("transferId", session.id)
                .put("fileIndex", 0)
                .put("status", session.status)
                .put("bytesReceived", session.bytesReceived)
                .put("serverSha256", session.serverSha256)
        } catch (failure: DropHttpFailure) {
            if (failure.error != "canceled") {
                session.status = "failed"
                session.error = failure.error
                session.tempFile.delete()
            }
            throw failure
        } catch (error: IOException) {
            session.status = "failed"
            session.error = "upload_io_failed"
            session.tempFile.delete()
            throw error
        }
    }

    private fun finalizeTransfer(transferId: String, json: JSONObject, deviceId: String): JSONObject {
        val session = sessions[transferId] ?: throw DropHttpFailure(404, "not_found", "Transfer was not found")
        ensureLive(session)
        ensureOwner(session, deviceId)
        session.finalizeResponse?.let { return it }

        val bytesSent = json.getLong("bytesSent")
        val finalSha256 = json.getString("finalSha256").lowercase()
        fun failure(code: String, message: String): JSONObject {
            session.status = "failed"
            session.error = code
            session.tempFile.delete()
            val response = finalizeJson(session, message)
            session.finalizeResponse = response
            onEvent(AndroidDropEvent("Mac drop failed", error = message))
            recordHistory(session)
            return response
        }

        if (session.status != "uploaded") return failure("not_uploaded", "Upload must complete before finalize")
        if (bytesSent != session.expectedSize) return failure("bytes_sent_mismatch", "Finalize byte count does not match expected size")
        if (finalSha256 != session.serverSha256) return failure("sha256_mismatch", "Finalize hash does not match streamed hash")
        if (session.clientSha256 != null && session.clientSha256 != session.serverSha256) {
            return failure("client_sha256_mismatch", "Create-transfer hash does not match streamed hash")
        }

        val savedPath = try {
            saveToDownloads(session)
        } catch (error: Exception) {
            return failure("final_save_failed", "Could not save to Downloads: ${error.message ?: "unknown error"}")
        }
        session.status = "complete"
        session.savedPath = savedPath
        session.error = null
        session.tempFile.delete()
        val response = finalizeJson(session, null)
        session.finalizeResponse = response
        onEvent(AndroidDropEvent("Saved ${session.safeName}", savedPath = savedPath))
        recordHistory(session)
        return response
    }

    private fun recordHistory(session: DropSession) {
        val status = when (session.status) {
            "complete" -> TransferHistoryEntry.STATUS_COMPLETE
            "canceled" -> TransferHistoryEntry.STATUS_CANCELED
            else -> TransferHistoryEntry.STATUS_FAILED
        }
        history.append(
            TransferHistoryEntry(
                id = session.id,
                direction = TransferHistoryEntry.DIRECTION_RECEIVED,
                filename = session.safeName,
                size = session.expectedSize,
                peerName = identityStore.trustedMac()?.deviceName.orEmpty(),
                completedAt = System.currentTimeMillis(),
                status = status,
                savedPath = session.savedPath,
                error = session.error
            )
        )
    }

    private fun saveToDownloads(session: DropSession): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = context.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, session.safeName)
                put(MediaStore.MediaColumns.MIME_TYPE, session.mimeType ?: "application/octet-stream")
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/Linkit Drop")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IOException("Could not create Downloads entry")
            try {
                resolver.openOutputStream(uri)?.use { output ->
                    FileInputStream(session.tempFile).use { input -> input.copyTo(output, 1024 * 1024) }
                } ?: throw IOException("Could not open Downloads entry")
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
                return "Downloads/Linkit Drop/${session.safeName}"
            } catch (error: Exception) {
                runCatching { resolver.delete(uri, null, null) }
                throw error
            }
        }

        val dir = File(context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), "Linkit Drop").apply { mkdirs() }
        val target = collisionFile(dir, session.safeName)
        session.tempFile.copyTo(target, overwrite = false)
        return target.absolutePath
    }

    private fun verifyUploadSignature(request: DropRequest, transferId: String, index: Int, uploadToken: String): String {
        val trusted = trustedMac()
        val deviceId = request.headers["x-linkit-device-id"] ?: throw DropHttpFailure(401, "missing_upload_signature", "Signed upload request is required")
        if (deviceId != trusted.deviceId) throw DropHttpFailure(401, "unknown_device", "Device is not paired")
        val timestamp = request.headers["x-linkit-timestamp"]?.toLongOrNull()
            ?: throw DropHttpFailure(401, "invalid_timestamp", "Signed upload timestamp is invalid")
        val nonce = request.headers["x-linkit-nonce"] ?: throw DropHttpFailure(401, "missing_nonce", "Signed upload nonce is required")
        val signature = request.headers["x-linkit-signature"]?.let { Base64.decode(it, Base64.DEFAULT) }
            ?: throw DropHttpFailure(401, "invalid_upload_signature", "Upload signature is invalid")
        val now = System.currentTimeMillis()
        if (kotlin.math.abs(now - timestamp) > 60_000) {
            throw DropHttpFailure(401, "clock_skew", "Signed upload timestamp is outside tolerance")
        }
        val canonical = LinkitUploadSignature.canonicalString(
            deviceId = deviceId,
            transferId = transferId,
            fileIndex = index,
            uploadToken = uploadToken,
            contentLength = request.contentLength,
            timestamp = timestamp.toString(),
            nonce = nonce
        )
        val verifier = Signature.getInstance("SHA256withECDSA")
        verifier.initVerify(publicKeyFromX963(trusted.publicKey))
        verifier.update(canonical.toByteArray(Charsets.UTF_8))
        if (!verifier.verify(signature)) {
            throw DropHttpFailure(401, "invalid_upload_signature", "Upload signature is invalid")
        }
        if (!nonceCache.insert(deviceId, nonce)) {
            throw DropHttpFailure(401, "nonce_replay", "Signed request nonce was already used")
        }
        return deviceId
    }

    private fun verifySigned(request: DropRequest, body: ByteArray): String {
        val trusted = trustedMac()
        val deviceId = request.headers["x-linkit-device-id"] ?: throw DropHttpFailure(401, "missing_signature", "Signed request is required")
        if (deviceId != trusted.deviceId) throw DropHttpFailure(401, "unknown_device", "Device is not paired")
        val timestamp = request.headers["x-linkit-timestamp"]?.toLongOrNull()
            ?: throw DropHttpFailure(401, "invalid_timestamp", "Signed request timestamp is invalid")
        val nonce = request.headers["x-linkit-nonce"] ?: throw DropHttpFailure(401, "missing_nonce", "Signed request nonce is required")
        val signature = request.headers["x-linkit-signature"]?.let { Base64.decode(it, Base64.DEFAULT) }
            ?: throw DropHttpFailure(401, "invalid_signature", "Signed request signature is invalid")
        val now = System.currentTimeMillis()
        if (kotlin.math.abs(now - timestamp) > 60_000) {
            throw DropHttpFailure(401, "clock_skew", "Signed request timestamp is outside tolerance")
        }

        val bodyHash = MessageDigest.getInstance("SHA-256").digest(body).toHex()
        val canonical = listOf(request.method.uppercase(), request.path, timestamp.toString(), nonce, bodyHash).joinToString("\n")
        val verifier = Signature.getInstance("SHA256withECDSA")
        verifier.initVerify(publicKeyFromX963(trusted.publicKey))
        verifier.update(canonical.toByteArray(Charsets.UTF_8))
        if (!verifier.verify(signature)) {
            throw DropHttpFailure(401, "invalid_signature", "Signed request signature is invalid")
        }
        if (!nonceCache.insert(deviceId, nonce)) {
            throw DropHttpFailure(401, "nonce_replay", "Signed request nonce was already used")
        }
        return deviceId
    }

    private fun readRequest(input: InputStream): DropRequest {
        val header = ByteArrayOutputStream()
        var matched = 0
        val delimiter = byteArrayOf(13, 10, 13, 10)
        while (true) {
            val byte = input.read()
            if (byte == -1) throw DropHttpFailure(400, "bad_request", "Missing HTTP headers")
            header.write(byte)
            matched = if (byte.toByte() == delimiter[matched]) matched + 1 else if (byte == 13) 1 else 0
            if (matched == delimiter.size) break
            if (header.size() > 64 * 1024) throw DropHttpFailure(400, "headers_too_large", "Request headers are too large")
        }

        val headerBytes = header.toByteArray()
        val text = String(headerBytes.copyOf(headerBytes.size - delimiter.size), Charsets.UTF_8)
        val lines = text.split("\r\n")
        val requestLine = lines.first().split(" ")
        if (requestLine.size != 3) throw DropHttpFailure(400, "bad_request", "Invalid request line")
        val headers = mutableMapOf<String, String>()
        for (line in lines.drop(1)) {
            val index = line.indexOf(':')
            if (index > 0) headers[line.substring(0, index).trim().lowercase()] = line.substring(index + 1).trim()
        }
        val contentLength = headers["content-length"]?.toLongOrNull() ?: 0L
        if (contentLength < 0) throw DropHttpFailure(400, "invalid_content_length", "Content-Length is invalid")
        return DropRequest(
            method = requestLine[0],
            target = requestLine[1],
            path = requestLine[1].substringBefore("?"),
            headers = headers,
            contentLength = contentLength,
            input = input
        )
    }

    private fun readBody(request: DropRequest, maxBytes: Int): ByteArray {
        if (request.contentLength > maxBytes) throw DropHttpFailure(400, "body_too_large", "Request body is too large")
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        var remaining = request.contentLength
        while (remaining > 0) {
            val read = request.input.read(buffer, 0, min(buffer.size.toLong(), remaining).toInt())
            if (read == -1) throw DropHttpFailure(400, "connection_closed", "Client disconnected before request body completed")
            output.write(buffer, 0, read)
            remaining -= read
        }
        return output.toByteArray()
    }

    private fun writeResponse(output: OutputStream, response: DropResponse) {
        val head = buildString {
            append("HTTP/1.1 ${response.status} ${reason(response.status)}\r\n")
            append("Content-Type: application/json; charset=utf-8\r\n")
            append("Content-Length: ${response.body.size}\r\n")
            append("Connection: close\r\n\r\n")
        }
        output.write(head.toByteArray(Charsets.UTF_8))
        output.write(response.body)
        output.flush()
    }

    private fun jsonResponse(status: Int, error: String, message: String): DropResponse {
        return jsonResponse(status, JSONObject().put("error", error).put("message", message))
    }

    private fun jsonResponse(status: Int, json: JSONObject): DropResponse {
        return DropResponse(status, json.toString().toByteArray(Charsets.UTF_8))
    }

    private fun createdFileJson(session: DropSession) = JSONObject()
        .put("index", 0)
        .put("name", session.originalName)
        .put("safeName", session.safeName)
        .put("size", session.expectedSize)
        .put("mimeType", session.mimeType)
        .put("status", session.status)
        .put("uploadUrl", "/v1/transfers/${session.id}/files/0")
        .put("uploadToken", session.uploadToken)
        .put("uploadTokenExpiresAt", "")

    private fun finalizeJson(session: DropSession, message: String?) = JSONObject()
        .put("transferId", session.id)
        .put("status", session.status)
        .put("files", JSONArray().put(JSONObject()
            .put("index", 0)
            .put("name", session.originalName)
            .put("size", session.expectedSize)
            .put("status", session.status)
            .put("savedPath", session.savedPath)
            .put("bytesReceived", session.bytesReceived)
            .put("sha256", session.serverSha256)
            .put("error", session.error)))
        .put("savedPath", session.savedPath)
        .put("bytesReceived", session.bytesReceived)
        .put("sha256", session.serverSha256)
        .put("error", session.error)
        .put("message", message)

    private fun statusJson(session: DropSession) = JSONObject()
        .put("transferId", session.id)
        .put("status", session.status)
        .put("clientDeviceId", session.clientDeviceId)
        .put("bytesReceived", session.bytesReceived)
        .put("expectedSize", session.expectedSize)
        .put("serverSha256", session.serverSha256)
        .put("savedPath", session.savedPath)
        .put("error", session.error)

    private fun deviceStatusJson(): JSONObject {
        val identity = identityStore.identity()
        val json = JSONObject()
            .put("protocolVersion", 1)
            .put("deviceId", identity.deviceId)
            .put("deviceName", identity.deviceName)
            .put("platform", "android")
            .put("status", "connected")
            .put("receivePort", PORT)
        BatteryStatus.percent(context)?.let { json.put("batteryPercent", it) }
        return json
    }

    private fun ensureOwner(session: DropSession, deviceId: String) {
        if (session.clientDeviceId != deviceId) {
            throw DropHttpFailure(401, "client_device_mismatch", "Signed device does not own this transfer")
        }
    }

    private fun ensureLive(session: DropSession) {
        if (System.currentTimeMillis() > session.expiresAtMillis) {
            sessions.remove(session.id)
            session.tempFile.delete()
            throw DropHttpFailure(401, "session_expired", "Transfer session expired")
        }
    }

    private fun sweepExpiredSessions() {
        val now = System.currentTimeMillis()
        sessions.entries.removeIf { entry ->
            val expired = now > entry.value.expiresAtMillis
            if (expired) entry.value.tempFile.delete()
            expired
        }
    }

    private fun trustedMac(): TrustedMac {
        return identityStore.trustedMac() ?: throw DropHttpFailure(401, "unknown_device", "Pair with Mac first")
    }

    private fun token(byteCount: Int): String {
        val bytes = ByteArray(byteCount)
        random.nextBytes(bytes)
        return Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    }

    private fun sanitizeFilename(input: String): String {
        val cleaned = input
            .replace("/", "_")
            .replace("\\", "_")
            .replace("..", "_")
            .trim()
            .trimStart('.')
            .ifBlank { "linkit-file" }
        if (cleaned.length <= 120) return cleaned
        val extensionIndex = cleaned.lastIndexOf('.')
        val extension = cleaned.substring(extensionIndex).takeIf { extensionIndex in 1 until cleaned.lastIndex && it.length <= 16 }.orEmpty()
        return cleaned.take(120 - extension.length) + extension
    }

    private fun collisionFile(dir: File, name: String): File {
        val base = name.substringBeforeLast('.', name)
        val ext = name.substringAfterLast('.', "").takeIf { it.isNotBlank() }?.let { ".$it" }.orEmpty()
        for (attempt in 0..9999) {
            val candidate = if (attempt == 0) File(dir, name) else File(dir, "$base ($attempt)$ext")
            if (!candidate.exists()) return candidate
        }
        throw IOException("Could not allocate destination filename")
    }

    private fun publicKeyFromX963(publicKeyBase64: String): ECPublicKey {
        val bytes = Base64.decode(publicKeyBase64, Base64.DEFAULT)
        require(bytes.size == 65 && bytes[0].toInt() == 0x04) { "Invalid P-256 public key" }
        val params = AlgorithmParameters.getInstance("EC")
        params.init(ECGenParameterSpec("secp256r1"))
        val ecSpec = params.getParameterSpec(ECParameterSpec::class.java)
        val point = ECPoint(
            BigInteger(1, bytes.copyOfRange(1, 33)),
            BigInteger(1, bytes.copyOfRange(33, 65))
        )
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point, ecSpec)) as ECPublicKey
    }

    private fun reason(status: Int): String = when (status) {
        200 -> "OK"
        201 -> "Created"
        400 -> "Bad Request"
        401 -> "Unauthorized"
        404 -> "Not Found"
        409 -> "Conflict"
        500 -> "Internal Server Error"
        else -> "OK"
    }

    companion object {
        const val PORT = 52718
    }
}

private data class DropRequest(
    val method: String,
    val target: String,
    val path: String,
    val headers: Map<String, String>,
    val contentLength: Long,
    val input: InputStream
)

private data class DropResponse(val status: Int, val body: ByteArray)

private data class DropSession(
    val id: String,
    val clientDeviceId: String,
    val originalName: String,
    val safeName: String,
    val expectedSize: Long,
    val mimeType: String?,
    val clientSha256: String?,
    val uploadToken: String,
    val tempFile: File,
    val expiresAtMillis: Long = System.currentTimeMillis() + SESSION_TTL_MILLIS,
    var uploadTokenConsumed: Boolean = false,
    var status: String = "created",
    var bytesReceived: Long = 0,
    var serverSha256: String? = null,
    var savedPath: String? = null,
    var error: String? = null,
    var finalizeResponse: JSONObject? = null
)

private class DropHttpFailure(val status: Int, val error: String, override val message: String) : Exception(message)

private class AndroidNonceCache(private val ttlMillis: Long = 120_000, private val maxEntries: Int = 4096) {
    private val entries = ConcurrentHashMap<String, Long>()

    fun insert(deviceId: String, nonce: String): Boolean {
        val now = System.currentTimeMillis()
        entries.entries.removeIf { it.value <= now }
        if (entries.size >= maxEntries) {
            entries.entries.sortedBy { it.value }
                .take(entries.size - maxEntries + 1)
                .forEach { entries.remove(it.key) }
        }
        val key = "$deviceId:$nonce"
        return entries.putIfAbsent(key, now + ttlMillis) == null
    }
}
