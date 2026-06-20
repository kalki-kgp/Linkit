import CryptoKit
import Foundation

public struct OutgoingTransferResult: Equatable {
    public let fileURL: URL
    public let transferId: String
    public let savedPath: String?
    public let sha256: String
    public let bytesSent: Int64
}

public struct OutgoingTransferProgress: Equatable {
    public let fileURL: URL
    public let fileIndex: Int
    public let fileCount: Int
    public let fileBytesSent: Int64
    public let fileSize: Int64
}

public final class LinkitCancellationToken {
    private let lock = NSLock()
    private var canceled = false
    private var handlers: [() -> Void] = []

    public init() {}

    public var isCanceled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return canceled
    }

    public func cancel() {
        let callbacks: [() -> Void]
        lock.lock()
        if canceled {
            lock.unlock()
            return
        }
        canceled = true
        callbacks = handlers
        handlers.removeAll()
        lock.unlock()
        callbacks.forEach { $0() }
    }

    fileprivate func throwIfCanceled() throws {
        if isCanceled {
            throw CancellationError()
        }
    }

    fileprivate func onCancel(_ handler: @escaping () -> Void) {
        lock.lock()
        if canceled {
            lock.unlock()
            handler()
            return
        }
        handlers.append(handler)
        lock.unlock()
    }
}

final class OutgoingTransferClient {
    private let identity: LinkitIdentity
    private let logger: LinkitLogger
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(identity: LinkitIdentity, logger: LinkitLogger) {
        self.identity = identity
        self.logger = logger
    }

    func send(
        files: [URL],
        to device: TrustedDevice,
        cancellation: LinkitCancellationToken? = nil,
        onProgress: ((OutgoingTransferProgress) -> Void)? = nil
    ) throws -> [OutgoingTransferResult] {
        guard device.platform.lowercased() == "android" else {
            throw HTTPFailure.badRequest("unsupported_target", "Target device is not Android")
        }
        guard let host = device.lastKnownHost, let port = device.receivePort else {
            throw HTTPFailure.badRequest("missing_android_receiver", "Open Linkit on Android once so it can register its receiver")
        }

        let baseURL = httpBaseURL(host: host, port: port)
        var results: [OutgoingTransferResult] = []
        for (index, file) in files.enumerated() {
            try cancellation?.throwIfCanceled()
            results.append(try send(file: file, baseURL: baseURL, fileIndex: index, fileCount: files.count, pairingSecret: device.pairingSecret, cancellation: cancellation, onProgress: onProgress))
        }
        return results
    }

    func status(of device: TrustedDevice) throws -> AndroidDeviceStatusResponse {
        guard device.platform.lowercased() == "android" else {
            throw HTTPFailure.badRequest("unsupported_target", "Target device is not Android")
        }
        guard let host = device.lastKnownHost, let port = device.receivePort else {
            throw HTTPFailure.badRequest("missing_android_receiver", "Android receiver address is missing")
        }

        let baseURL = httpBaseURL(host: host, port: port)
        let path = "/v1/devices/self/status"
        let response: AndroidDeviceStatusResponse = try executeJSON(
            signedRequest(method: "GET", url: baseURL + path, path: path, body: Data()),
            expectedStatus: 200
        )
        guard response.protocolVersion == 1,
              response.platform.lowercased() == "android",
              response.deviceId == device.deviceId
        else {
            throw HTTPFailure.unauthorized("device_status_mismatch", "Android status response did not match the connected device")
        }
        return response
    }

    func fetchPhonebook(of device: TrustedDevice) throws -> PhonebookResponse {
        guard device.platform.lowercased() == "android" else {
            throw HTTPFailure.badRequest("unsupported_target", "Target device is not Android")
        }
        guard let host = device.lastKnownHost, let port = device.receivePort else {
            throw HTTPFailure.badRequest("missing_android_receiver", "Android receiver address is missing")
        }

        let baseURL = httpBaseURL(host: host, port: port)
        let path = "/v1/phonebook"
        let result = try execute(signedRequest(method: "GET", url: baseURL + path, path: path, body: Data()))
        guard result.status == 200 else {
            throw decodeFailure(status: result.status, data: result.data)
        }
        // The address book and call history are sensitive PII, so the receiver seals the
        // response with the pairing secret. This is the one route that returns ciphertext.
        let plaintext = try LinkitWireCrypto.open(pairingSecret: device.pairingSecret, body: result.data)
        return try decoder.decode(PhonebookResponse.self, from: plaintext)
    }

    private func send(
        file: URL,
        baseURL: String,
        fileIndex: Int,
        fileCount: Int,
        pairingSecret: String?,
        cancellation: LinkitCancellationToken?,
        onProgress: ((OutgoingTransferProgress) -> Void)?
    ) throws -> OutgoingTransferResult {
        try cancellation?.throwIfCanceled()
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .localizedNameKey])
        guard values.isRegularFile == true else {
            throw HTTPFailure.badRequest("not_regular_file", "Only regular files can be sent")
        }
        let size = Int64(values.fileSize ?? 0)
        let filename = values.localizedName ?? file.lastPathComponent
        let sha256 = try sha256Hex(file)
        let createBody = try encoder.encode(
            CreateTransferRequest(
                clientDeviceId: identity.deviceId,
                files: [
                    TransferFileRequest(
                        name: filename,
                        size: size,
                        mimeType: nil,
                        clientSha256: sha256
                    )
                ]
            )
        )
        let createPath = "/v1/transfers"
        let createResponse: CreateTransferResponse = try executeJSON(
            signedRequest(method: "POST", url: baseURL + createPath, path: createPath, body: createBody),
            expectedStatus: 201
        )

        guard let pskString = pairingSecret, let psk = Data(base64Encoded: pskString) else {
            throw HTTPFailure.unauthorized("not_paired_for_encryption", "No encryption key for this device. Re-pair to enable encryption.")
        }
        let transferKey = LinkitSecretBox.transferKey(pairingSecret: psk, transferId: createResponse.transferId, fileIndex: 0)
        let encryptedFile = try encryptFileToTemp(file, key: transferKey)
        defer { try? FileManager.default.removeItem(at: encryptedFile) }

        do {
            try cancellation?.throwIfCanceled()
            let uploadPath = "/v1/transfers/\(createResponse.transferId)/files/0"
            var uploadRequest = URLRequest(url: try absoluteURL(baseURL + uploadPath))
            uploadRequest.httpMethod = "PUT"
            uploadRequest.setValue(createResponse.uploadToken, forHTTPHeaderField: "X-Linkit-Upload-Token")
            uploadRequest.setValue(identity.deviceId, forHTTPHeaderField: "X-Linkit-Client-Device-Id")
            uploadRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            uploadRequest.setValue("\(size)", forHTTPHeaderField: "Content-Length")
            uploadRequest.timeoutInterval = uploadTimeout(forBytes: size)
            try signUpload(
                &uploadRequest,
                transferId: createResponse.transferId,
                fileIndex: 0,
                uploadToken: createResponse.uploadToken,
                contentLength: size
            )
            try executeUpload(uploadRequest, file: encryptedFile, expectedStatus: 200, expectedBytes: size, cancellation: cancellation) { sent in
                onProgress?(
                    OutgoingTransferProgress(
                        fileURL: file,
                        fileIndex: fileIndex,
                        fileCount: fileCount,
                        fileBytesSent: sent,
                        fileSize: size
                    )
                )
            }

            try cancellation?.throwIfCanceled()
        } catch is CancellationError {
            try? cancelTransfer(baseURL: baseURL, transferId: createResponse.transferId)
            throw CancellationError()
        }

        let finalizeBody = try encoder.encode(FinalizeRequest(bytesSent: size, finalSha256: sha256))
        let finalizePath = "/v1/transfers/\(createResponse.transferId)/finalize"
        let finalizeResponse: FinalizeResponse = try executeJSON(
            signedRequest(
                method: "POST",
                url: baseURL + finalizePath,
                path: finalizePath,
                body: finalizeBody
            ),
            expectedStatus: 200
        )
        logger.info("sent file to Android transferId=\(createResponse.transferId) name=\(filename) bytes=\(size)")
        return OutgoingTransferResult(
            fileURL: file,
            transferId: createResponse.transferId,
            savedPath: finalizeResponse.savedPath,
            sha256: sha256,
            bytesSent: size
        )
    }

    private func signedRequest(method: String, url: String, path: String, body: Data) throws -> URLRequest {
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        let nonce = try LinkitRandom.token(byteCount: 16)
        let bodyHash = SHA256.hash(data: body).linkitHex
        let canonical = SignedRequestVerifier.canonicalString(
            method: method,
            path: path,
            timestamp: timestamp,
            nonce: nonce,
            bodyHash: bodyHash
        )
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let signature = try identity.privateKey.signature(for: digest).derRepresentation.base64EncodedString()

        var request = URLRequest(url: try absoluteURL(url))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 8
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(identity.deviceId, forHTTPHeaderField: "X-Linkit-Device-Id")
        request.setValue(timestamp, forHTTPHeaderField: "X-Linkit-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-Linkit-Nonce")
        request.setValue(signature, forHTTPHeaderField: "X-Linkit-Signature")
        return request
    }

    func sendAction(_ action: LinkitActionRequest, to device: TrustedDevice) throws -> LinkitActionResponse {
        guard device.platform.lowercased() == "android" else {
            throw HTTPFailure.badRequest("unsupported_target", "Target device is not Android")
        }
        guard let host = device.lastKnownHost, let port = device.receivePort else {
            throw HTTPFailure.badRequest("missing_android_receiver", "Open Linkit on Android once so it can register its receiver")
        }
        let baseURL = httpBaseURL(host: host, port: port)
        let plaintext = try encoder.encode(action)
        let body = try LinkitWireCrypto.seal(pairingSecret: device.pairingSecret, plaintext: plaintext)
        let path = "/v1/actions"
        return try executeJSON(
            signedRequest(method: "POST", url: baseURL + path, path: path, body: body),
            expectedStatus: 200
        )
    }

    private func cancelTransfer(baseURL: String, transferId: String) throws {
        let path = "/v1/transfers/\(transferId)"
        _ = try executeJSON(
            signedRequest(method: "DELETE", url: baseURL + path, path: path, body: Data()),
            expectedStatus: 200
        ) as TransferStatusResponse
    }

    private func signUpload(
        _ request: inout URLRequest,
        transferId: String,
        fileIndex: Int,
        uploadToken: String,
        contentLength: Int64
    ) throws {
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        let nonce = try LinkitRandom.token(byteCount: 16)
        let canonical = SignedRequestVerifier.uploadCanonicalString(
            deviceId: identity.deviceId,
            transferId: transferId,
            fileIndex: fileIndex,
            uploadToken: uploadToken,
            contentLength: contentLength,
            timestamp: timestamp,
            nonce: nonce
        )
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let signature = try identity.privateKey.signature(for: digest).derRepresentation.base64EncodedString()
        request.setValue(identity.deviceId, forHTTPHeaderField: "X-Linkit-Device-Id")
        request.setValue(timestamp, forHTTPHeaderField: "X-Linkit-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-Linkit-Nonce")
        request.setValue(signature, forHTTPHeaderField: "X-Linkit-Signature")
    }

    private func executeJSON<T: Decodable>(_ request: URLRequest, expectedStatus: Int) throws -> T {
        let result = try execute(request)
        guard result.status == expectedStatus else {
            throw decodeFailure(status: result.status, data: result.data)
        }
        return try decoder.decode(T.self, from: result.data)
    }

    private func executeUpload(
        _ request: URLRequest,
        file: URL,
        expectedStatus: Int,
        expectedBytes: Int64,
        cancellation: LinkitCancellationToken?,
        onProgress: ((Int64) -> Void)? = nil
    ) throws {
        try ensureOffMainThread()
        let semaphore = DispatchSemaphore(value: 0)
        var taskResult: Result<OutgoingHTTPResult, Error>!
        let progressDelegate = UploadProgressDelegate(expectedBytes: expectedBytes, onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: progressDelegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        onProgress?(0)
        let task = session.uploadTask(with: request, fromFile: file) { data, response, error in
            if let error {
                taskResult = .failure(error)
            } else if let http = response as? HTTPURLResponse {
                taskResult = .success(OutgoingHTTPResult(status: http.statusCode, data: data ?? Data()))
            } else {
                taskResult = .failure(HTTPFailure.badRequest("missing_http_response", "Android receiver did not return an HTTP response"))
            }
            semaphore.signal()
        }
        task.resume()
        cancellation?.onCancel { task.cancel() }
        semaphore.wait()
        try cancellation?.throwIfCanceled()
        let result = try taskResult.get()
        guard result.status == expectedStatus else {
            throw decodeFailure(status: result.status, data: result.data)
        }
        onProgress?(expectedBytes)
    }

    private func execute(_ request: URLRequest) throws -> OutgoingHTTPResult {
        try ensureOffMainThread()
        let semaphore = DispatchSemaphore(value: 0)
        var taskResult: Result<OutgoingHTTPResult, Error>!
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                taskResult = .failure(error)
            } else if let http = response as? HTTPURLResponse {
                taskResult = .success(OutgoingHTTPResult(status: http.statusCode, data: data ?? Data()))
            } else {
                taskResult = .failure(HTTPFailure.badRequest("missing_http_response", "Android receiver did not return an HTTP response"))
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return try taskResult.get()
    }

    private func decodeFailure(status: Int, data: Data) -> HTTPFailure {
        if let error = try? decoder.decode(ErrorResponse.self, from: data) {
            return HTTPFailure(status: status, error: error.error, message: error.message)
        }
        return HTTPFailure(status: status, error: "send_failed", message: "Android receiver returned HTTP \(status)")
    }

    /// CTR-encrypts `source` to a temp file (same size) for upload. Caller removes it.
    private func encryptFileToTemp(_ source: URL, key: SymmetricKey) throws -> URL {
        let cipher = try LinkitStreamCipher(key: key)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkit-enc-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
            throw HTTPFailure.badRequest("temp_create_failed", "Could not create encryption temp file")
        }
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: temp)
        defer { try? writer.close() }
        while true {
            let chunk = try reader.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            try writer.write(contentsOf: cipher.update(chunk))
        }
        return temp
    }

    private func sha256Hex(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().linkitHex
    }

    private func absoluteURL(_ text: String) throws -> URL {
        guard let url = URL(string: text) else {
            throw HTTPFailure.badRequest("invalid_url", "Android receiver URL is invalid")
        }
        return url
    }

    private func httpBaseURL(host: String, port: UInt16) -> String {
        "http://\(host.contains(":") ? "[\(host)]" : host):\(port)"
    }

    private func uploadTimeout(forBytes bytes: Int64) -> TimeInterval {
        max(30, min(900, Double(max(bytes, 1)) / (512 * 1024)))
    }

    private func ensureOffMainThread() throws {
        guard !Thread.isMainThread else {
            throw HTTPFailure.badRequest("main_thread_network", "Outgoing Android requests must run off the main thread")
        }
    }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let expectedBytes: Int64
    private let onProgress: ((Int64) -> Void)?

    init(expectedBytes: Int64, onProgress: ((Int64) -> Void)?) {
        self.expectedBytes = expectedBytes
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let expected = expectedBytes > 0 ? expectedBytes : max(0, totalBytesExpectedToSend)
        let clamped = expected > 0 ? min(expected, totalBytesSent) : max(0, totalBytesSent)
        onProgress?(clamped)
    }
}

private struct OutgoingHTTPResult {
    let status: Int
    let data: Data
}
