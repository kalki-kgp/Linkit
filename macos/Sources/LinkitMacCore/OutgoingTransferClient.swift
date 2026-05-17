import CryptoKit
import Foundation

public struct OutgoingTransferResult: Equatable {
    public let fileURL: URL
    public let transferId: String
    public let savedPath: String?
    public let sha256: String
    public let bytesSent: Int64
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

    func send(files: [URL], to device: TrustedDevice) throws -> [OutgoingTransferResult] {
        guard device.platform.lowercased() == "android" else {
            throw HTTPFailure.badRequest("unsupported_target", "Target device is not Android")
        }
        guard let host = device.lastKnownHost, let port = device.receivePort else {
            throw HTTPFailure.badRequest("missing_android_receiver", "Open Linkit on Android once so it can register its receiver")
        }

        let baseURL = httpBaseURL(host: host, port: port)
        var results: [OutgoingTransferResult] = []
        for file in files {
            results.append(try send(file: file, baseURL: baseURL))
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

    private func send(file: URL, baseURL: String) throws -> OutgoingTransferResult {
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
        try executeUpload(uploadRequest, file: file, expectedStatus: 200)

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

    private func executeUpload(_ request: URLRequest, file: URL, expectedStatus: Int) throws {
        try ensureOffMainThread()
        let semaphore = DispatchSemaphore(value: 0)
        var taskResult: Result<OutgoingHTTPResult, Error>!
        URLSession.shared.uploadTask(with: request, fromFile: file) { data, response, error in
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
        let result = try taskResult.get()
        guard result.status == expectedStatus else {
            throw decodeFailure(status: result.status, data: result.data)
        }
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

private struct OutgoingHTTPResult {
    let status: Int
    let data: Data
}
