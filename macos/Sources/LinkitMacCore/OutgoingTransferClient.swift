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

        let baseURL = "http://\(host.contains(":") ? "[\(host)]" : host):\(port)"
        var results: [OutgoingTransferResult] = []
        for file in files {
            results.append(try send(file: file, baseURL: baseURL))
        }
        return results
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

        var uploadRequest = URLRequest(url: try absoluteURL(baseURL + createResponse.uploadUrl))
        uploadRequest.httpMethod = "PUT"
        uploadRequest.setValue(createResponse.uploadToken, forHTTPHeaderField: "X-Linkit-Upload-Token")
        uploadRequest.setValue(identity.deviceId, forHTTPHeaderField: "X-Linkit-Client-Device-Id")
        uploadRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        uploadRequest.setValue("\(size)", forHTTPHeaderField: "Content-Length")
        try executeUpload(uploadRequest, file: file, expectedStatus: 200)

        let finalizeBody = try encoder.encode(FinalizeRequest(bytesSent: size, finalSha256: sha256))
        let finalizeResponse: FinalizeResponse = try executeJSON(
            signedRequest(
                method: "POST",
                url: baseURL + createResponse.finalizeUrl,
                path: createResponse.finalizeUrl,
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
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(identity.deviceId, forHTTPHeaderField: "X-Linkit-Device-Id")
        request.setValue(timestamp, forHTTPHeaderField: "X-Linkit-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-Linkit-Nonce")
        request.setValue(signature, forHTTPHeaderField: "X-Linkit-Signature")
        return request
    }

    private func executeJSON<T: Decodable>(_ request: URLRequest, expectedStatus: Int) throws -> T {
        let result = try execute(request)
        guard result.status == expectedStatus else {
            throw decodeFailure(status: result.status, data: result.data)
        }
        return try decoder.decode(T.self, from: result.data)
    }

    private func executeUpload(_ request: URLRequest, file: URL, expectedStatus: Int) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var taskResult: Result<OutgoingHTTPResult, Error>!
        URLSession.shared.uploadTask(with: request, fromFile: file) { data, response, error in
            if let error {
                taskResult = .failure(error)
            } else {
                taskResult = .success(OutgoingHTTPResult(status: (response as! HTTPURLResponse).statusCode, data: data ?? Data()))
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
        let semaphore = DispatchSemaphore(value: 0)
        var taskResult: Result<OutgoingHTTPResult, Error>!
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                taskResult = .failure(error)
            } else {
                taskResult = .success(OutgoingHTTPResult(status: (response as! HTTPURLResponse).statusCode, data: data ?? Data()))
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
}

private struct OutgoingHTTPResult {
    let status: Int
    let data: Data
}
