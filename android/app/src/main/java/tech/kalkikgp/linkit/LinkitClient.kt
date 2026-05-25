package tech.kalkikgp.linkit

import android.content.ContentResolver
import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okio.BufferedSink
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import android.util.Base64
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

private const val TAG = "Linkit"

data class CreateTransferResult(
    val transferId: String,
    val uploadUrl: String,
    val finalizeUrl: String,
    val statusUrl: String,
    val uploadToken: String
)

data class UploadResult(
    val bytesSent: Long,
    val sha256: String
)

data class SendResult(
    val transferId: String,
    val savedPath: String?,
    val sha256: String,
    val bytesSent: Long
)

open class LinkitHttpException(
    val statusCode: Int,
    val errorCode: String,
    override val message: String
) : Exception(message)

class TokenRejectedException(message: String) : LinkitHttpException(401, "token_rejected", message)
class PairingTrustException(message: String) : LinkitHttpException(0, "pairing_trust_failed", message)

object LinkitUploadSignature {
    fun canonicalString(
        deviceId: String,
        transferId: String,
        fileIndex: Int,
        uploadToken: String,
        contentLength: Long,
        timestamp: String,
        nonce: String
    ): String = listOf(
        "UPLOAD",
        deviceId,
        transferId,
        fileIndex.toString(),
        uploadToken,
        contentLength.toString(),
        timestamp,
        nonce
    ).joinToString("\n")
}

class LinkitClient(
    private val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .writeTimeout(0, TimeUnit.MILLISECONDS)
        .callTimeout(0, TimeUnit.MILLISECONDS)
        .build()
) {
    suspend fun pair(
        baseUrl: String,
        payload: MacPairingPayload,
        identityStore: IdentityStore,
        batteryPercent: Int?
    ): TrustedMac {
        val identity = identityStore.identity()
        val challengeSignature = identityStore.sign(
            LinkitPairingChallenge.canonicalString(
                macDeviceId = payload.deviceId,
                androidDeviceId = identity.deviceId,
                androidPublicKey = identity.publicKey,
                pairingToken = payload.pairingToken,
                challenge = payload.pairingChallenge
            )
        )
        val bodyJson = JSONObject()
            .put("deviceId", identity.deviceId)
            .put("deviceName", identity.deviceName)
            .put("platform", "android")
            .put("publicKey", identity.publicKey)
            .put("pairingToken", payload.pairingToken)
            .put("pairingChallenge", payload.pairingChallenge)
            .put("pairingChallengeSignature", challengeSignature)
            .put("receivePort", AndroidDropReceiver.PORT)
        batteryPercent?.let { bodyJson.put("batteryPercent", it) }

        val request = Request.Builder()
            .url("$baseUrl/v1/pair")
            .post(bodyJson.toString().toRequestBody("application/json; charset=utf-8".toMediaType()))
            .build()

        val json = executeJson(request)
        val mac = TrustedMac(
            deviceId = json.getString("deviceId"),
            deviceName = json.optString("deviceName", payload.deviceName),
            publicKey = json.getString("publicKey"),
            ip = payload.ip,
            port = payload.port
        )
        validatePairingResponse(payload, identity, mac, json)
        return mac
    }

    suspend fun registerReceiver(mac: TrustedMac, identityStore: IdentityStore, receivePort: Int, batteryPercent: Int?) {
        val baseUrl = PrivateLanTarget.baseUrl(mac.ip, mac.port)
        val bodyJson = JSONObject().put("receivePort", receivePort)
        batteryPercent?.let { bodyJson.put("batteryPercent", it) }
        val body = bodyJson.toString()
        val request = signedRequest(
            identityStore = identityStore,
            method = "POST",
            url = "$baseUrl/v1/devices/self",
            path = "/v1/devices/self",
            body = body
        )
        executeJson(request)
        MacPresence.touch()
        DebugTelemetry.recordEvent("client", "registerReceiver ok ${mac.ip}:${mac.port}")
    }

    suspend fun verifyMacEndpoint(mac: TrustedMac) {
        val baseUrl = PrivateLanTarget.baseUrl(mac.ip, mac.port)
        val challenge = IdentityStore.nonce()
        val body = JSONObject()
            .put("challenge", challenge)
            .toString()
        val request = Request.Builder()
            .url("$baseUrl/v1/identity/proof")
            .post(body.toRequestBody("application/json; charset=utf-8".toMediaType()))
            .build()
        val json = executeJson(request)
        val deviceId = json.optString("deviceId")
        val publicKey = json.optString("publicKey")
        val platform = json.optString("platform").lowercase()
        val echoedChallenge = json.optString("challenge")
        if (json.optInt("protocolVersion") != 1 ||
            platform != "macos" ||
            deviceId != mac.deviceId ||
            publicKey != mac.publicKey ||
            echoedChallenge != challenge
        ) {
            throw PairingTrustException("Discovered Mac did not match the paired identity")
        }
        val signatureData = runCatching {
            Base64.decode(json.optString("signature"), Base64.DEFAULT)
        }.getOrElse {
            throw PairingTrustException("Mac identity proof signature is invalid")
        }
        val canonical = LinkitIdentityProof.canonicalString(
            deviceId = deviceId,
            publicKey = publicKey,
            challenge = challenge
        )
        val verifier = Signature.getInstance("SHA256withECDSA")
        verifier.initVerify(publicKeyFromX963(publicKey))
        verifier.update(canonical.toByteArray(Charsets.UTF_8))
        if (!verifier.verify(signatureData)) {
            throw PairingTrustException("Mac identity proof signature was rejected")
        }
        DebugTelemetry.recordEvent("client", "verified Mac identity ${mac.ip}:${mac.port}")
    }

    suspend fun disconnect(mac: TrustedMac, identityStore: IdentityStore) {
        val baseUrl = PrivateLanTarget.baseUrl(mac.ip, mac.port)
        val request = signedRequest(
            identityStore = identityStore,
            method = "DELETE",
            url = "$baseUrl/v1/devices/self",
            path = "/v1/devices/self",
            body = ""
        )
        executeJson(request)
    }

    suspend fun sendAction(mac: TrustedMac, identityStore: IdentityStore, type: String, text: String) {
        val baseUrl = PrivateLanTarget.baseUrl(mac.ip, mac.port)
        val body = JSONObject()
            .put("type", type)
            .put("text", text)
            .toString()
        val request = signedRequest(
            identityStore = identityStore,
            method = "POST",
            url = "$baseUrl/v1/actions",
            path = "/v1/actions",
            body = body
        )
        executeJson(request)
        MacPresence.touch()
        DebugTelemetry.recordEvent("client", "sendAction ok type=$type bytes=${body.length}")
    }

    private fun validatePairingResponse(
        expected: MacPairingPayload,
        identity: AndroidIdentity,
        mac: TrustedMac,
        response: JSONObject
    ) {
        if (response.optInt("protocolVersion", 0) != 1) {
            throw PairingTrustException("Mac returned an unsupported pairing protocol")
        }
        if (response.optString("platform") != "macos") {
            throw PairingTrustException("Pairing response did not come from a Linkit Mac")
        }
        if (response.optString("trustedDeviceId").takeIf { it.isNotBlank() } != identity.deviceId) {
            throw PairingTrustException("Mac did not trust this Android identity")
        }
        if (mac.deviceId != expected.deviceId) {
            throw PairingTrustException("Scanned QR does not match the Mac that responded")
        }
        if (mac.publicKey != expected.publicKey) {
            throw PairingTrustException("Mac public key changed during pairing")
        }
        val derivedDeviceId = runCatching { IdentityStore.deviceIdFromPublicKey(mac.publicKey) }
            .getOrElse { throw PairingTrustException("Mac public key is invalid") }
        if (derivedDeviceId != mac.deviceId) {
            throw PairingTrustException("Mac device id does not match its public key")
        }
    }

    suspend fun sendFile(
        contentResolver: ContentResolver,
        mac: TrustedMac,
        identityStore: IdentityStore,
        file: PickedFile,
        onRetry: (String) -> Unit,
        onProgress: (Long, Long) -> Unit
    ): SendResult {
        var attempt = 0
        val baseUrl = PrivateLanTarget.baseUrl(mac.ip, mac.port)

        while (true) {
            var transferId: String? = null
            var finalizeStarted = false

            try {
                val create = createTransfer(baseUrl, identityStore, file)
                transferId = create.transferId

                val upload = uploadFile(
                    contentResolver = contentResolver,
                    baseUrl = baseUrl,
                    create = create,
                    identityStore = identityStore,
                    identity = identityStore.identity(),
                    file = file,
                    onProgress = onProgress
                )

                finalizeStarted = true
                val savedPath = try {
                    finalizeTransfer(baseUrl, identityStore, create.transferId, upload)
                } catch (io: IOException) {
                    Log.w(TAG, "finalize response lost, replaying same finalize payload", io)
                    finalizeTransfer(baseUrl, identityStore, create.transferId, upload)
                }

                return SendResult(
                    transferId = create.transferId,
                    savedPath = savedPath,
                    sha256 = upload.sha256,
                    bytesSent = upload.bytesSent
                )
            } catch (cancelled: CancellationException) {
                transferId?.let {
                    withContext(NonCancellable) {
                        runCatching { cancelTransfer(baseUrl, identityStore, it) }
                    }
                }
                throw cancelled
            } catch (token: TokenRejectedException) {
                throw token
            } catch (httpError: LinkitHttpException) {
                throw httpError
            } catch (io: IOException) {
                transferId?.let {
                    withContext(NonCancellable) {
                        runCatching { cancelTransfer(baseUrl, identityStore, it) }
                    }
                }

                if (!finalizeStarted && attempt == 0) {
                    attempt += 1
                    onRetry("Network dropped. Retrying once with a fresh stream.")
                    Log.w(TAG, "network drop, retrying once with a new transfer session", io)
                    continue
                }

                throw io
            }
        }
    }

    private suspend fun createTransfer(
        baseUrl: String,
        identityStore: IdentityStore,
        file: PickedFile
    ): CreateTransferResult {
        val identity = identityStore.identity()
        val fileJson = JSONObject()
            .put("name", file.name)
            .put("size", file.size)
            .put("mimeType", file.mimeType)
            .put("clientSha256", JSONObject.NULL)

        val bodyJson = JSONObject()
            .put("clientDeviceId", identity.deviceId)
            .put("files", JSONArray().put(fileJson))

        val body = bodyJson.toString()
        val request = signedRequest(
            identityStore = identityStore,
            method = "POST",
            url = "$baseUrl/v1/transfers",
            path = "/v1/transfers",
            body = body
        )

        val json = executeJson(request)
        val transferId = json.getString("transferId")
        val firstFile = json.optJSONArray("files")?.optJSONObject(0)
        return CreateTransferResult(
            transferId = transferId,
            uploadUrl = "/v1/transfers/$transferId/files/0",
            finalizeUrl = "/v1/transfers/$transferId/finalize",
            statusUrl = "/v1/transfers/$transferId",
            uploadToken = firstFile?.optString("uploadToken")?.takeIf { it.isNotBlank() }
                ?: json.getString("uploadToken")
        )
    }

    private suspend fun uploadFile(
        contentResolver: ContentResolver,
        baseUrl: String,
        create: CreateTransferResult,
        identityStore: IdentityStore,
        identity: AndroidIdentity,
        file: PickedFile,
        onProgress: (Long, Long) -> Unit
    ): UploadResult {
        val digest = MessageDigest.getInstance("SHA-256")
        val body = ContentUriRequestBody(contentResolver, file, digest, onProgress)

        val request = Request.Builder()
            .url(baseUrl + create.uploadUrl)
            .header("X-Linkit-Upload-Token", create.uploadToken)
            .header("X-Linkit-Client-Device-Id", identity.deviceId)
            .apply {
                signedUploadHeaders(
                    identityStore = identityStore,
                    identity = identity,
                    transferId = create.transferId,
                    fileIndex = 0,
                    uploadToken = create.uploadToken,
                    contentLength = file.size
                ).forEach { (name, value) -> header(name, value) }
            }
            .put(body)
            .build()

        executeJson(request)

        return UploadResult(
            bytesSent = body.bytesSent,
            sha256 = digest.digest().toHex()
        )
    }

    private suspend fun finalizeTransfer(
        baseUrl: String,
        identityStore: IdentityStore,
        transferId: String,
        upload: UploadResult
    ): String? {
        val finalizeUrl = "/v1/transfers/$transferId/finalize"
        val bodyJson = JSONObject()
            .put("bytesSent", upload.bytesSent)
            .put("finalSha256", upload.sha256)

        val request = signedRequest(
            identityStore = identityStore,
            method = "POST",
            url = baseUrl + finalizeUrl,
            path = finalizeUrl,
            body = bodyJson.toString()
        )

        val json = executeJson(request)
        MacPresence.touch()
        return json.optString("savedPath").takeIf { it.isNotBlank() }
    }

    private suspend fun cancelTransfer(baseUrl: String, identityStore: IdentityStore, transferId: String) {
        val path = "/v1/transfers/$transferId"
        val request = signedRequest(
            identityStore = identityStore,
            method = "DELETE",
            url = baseUrl + path,
            path = path,
            body = ""
        )
        runCatching { executeJson(request) }
    }

    private fun signedRequest(
        identityStore: IdentityStore,
        method: String,
        url: String,
        path: String,
        body: String
    ): Request {
        val identity = identityStore.identity()
        val timestamp = System.currentTimeMillis().toString()
        val nonce = IdentityStore.nonce()
        val bodyHash = MessageDigest.getInstance("SHA-256")
            .digest(body.toByteArray(Charsets.UTF_8))
            .toHex()
        val canonical = listOf(method.uppercase(), path, timestamp, nonce, bodyHash).joinToString("\n")
        val signature = identityStore.sign(canonical)
        val builder = Request.Builder()
            .url(url)
            .header("X-Linkit-Device-Id", identity.deviceId)
            .header("X-Linkit-Timestamp", timestamp)
            .header("X-Linkit-Nonce", nonce)
            .header("X-Linkit-Signature", signature)

        return when (method.uppercase()) {
            "POST" -> builder.post(body.toRequestBody("application/json; charset=utf-8".toMediaType())).build()
            "DELETE" -> builder.delete().build()
            "GET" -> builder.get().build()
            else -> error("Unsupported signed method $method")
        }
    }

    private fun signedUploadHeaders(
        identityStore: IdentityStore,
        identity: AndroidIdentity,
        transferId: String,
        fileIndex: Int,
        uploadToken: String,
        contentLength: Long
    ): Map<String, String> {
        val timestamp = System.currentTimeMillis().toString()
        val nonce = IdentityStore.nonce()
        val canonical = LinkitUploadSignature.canonicalString(
            deviceId = identity.deviceId,
            transferId = transferId,
            fileIndex = fileIndex,
            uploadToken = uploadToken,
            contentLength = contentLength,
            timestamp = timestamp,
            nonce = nonce
        )
        return mapOf(
            "X-Linkit-Device-Id" to identity.deviceId,
            "X-Linkit-Timestamp" to timestamp,
            "X-Linkit-Nonce" to nonce,
            "X-Linkit-Signature" to identityStore.sign(canonical)
        )
    }

    private suspend fun executeJson(request: Request): JSONObject {
        val response = http.newCall(request).await()
        response.use {
            val text = it.body?.string().orEmpty()
            val json = if (text.isBlank()) JSONObject() else JSONObject(text)
            if (it.isSuccessful) return json

            val error = json.optString("error", "http_${it.code}")
            val message = json.optString("message", "HTTP ${it.code}")
            if (it.code == 401 && error == "token_rejected") {
                throw TokenRejectedException(message)
            }
            throw LinkitHttpException(it.code, error, message)
        }
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
}

private class ContentUriRequestBody(
    private val contentResolver: ContentResolver,
    private val file: PickedFile,
    private val digest: MessageDigest,
    private val onProgress: (Long, Long) -> Unit
) : RequestBody() {
    @Volatile
    var bytesSent: Long = 0
        private set

    override fun contentType() = "application/octet-stream".toMediaType()

    override fun contentLength() = file.size

    override fun writeTo(sink: BufferedSink) {
        contentResolver.openInputStream(file.uri)?.use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val read = input.read(buffer)
                if (read == -1) break
                digest.update(buffer, 0, read)
                sink.write(buffer, 0, read)
                bytesSent += read.toLong()
                onProgress(bytesSent, file.size)
            }
        } ?: throw IOException("Could not open selected file")
    }

    companion object {
        private const val DEFAULT_BUFFER_SIZE = 1024 * 1024
    }
}

private suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
    continuation.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) {
            if (continuation.isCancelled) return
            continuation.resumeWithException(e)
        }

        override fun onResponse(call: Call, response: Response) {
            if (continuation.isCancelled) {
                response.close()
                return
            }
            continuation.resume(response)
        }
    })
}
