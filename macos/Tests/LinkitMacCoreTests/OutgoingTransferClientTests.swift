import CryptoKit
import Darwin
import XCTest
@testable import LinkitMacCore

final class OutgoingTransferClientTests: XCTestCase {
    func testSendsFileToAndroidShapedReceiver() throws {
        let key = P256.Signing.PrivateKey()
        let publicKey = key.publicKey.x963Representation
        let identity = LinkitIdentity(
            deviceId: LinkitDeviceId.fromPublicKey(publicKey),
            publicKey: publicKey.base64EncodedString(),
            privateKey: key
        )
        let receiver = try MockAndroidReceiver(macIdentity: identity)
        defer { receiver.stop() }

        let target = TrustedDevice(
            deviceId: "android-device",
            deviceName: "Pixel",
            platform: "android",
            publicKey: "unused",
            pairedAt: Date().iso8601(),
            lastKnownHost: "127.0.0.1",
            receivePort: receiver.port
        )
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkit-outgoing-\(UUID().uuidString).txt")
        try Data("hello android\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = try runOffMain {
            try OutgoingTransferClient(identity: identity, logger: LinkitLogger())
                .send(files: [file], to: target)
        }

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].bytesSent, 14)
        XCTAssertEqual(result[0].savedPath, "Downloads/Linkit Drop/linkit-outgoing.txt")
        XCTAssertEqual(receiver.uploadedBody, Data("hello android\n".utf8))
    }

    func testFetchesAndroidDeviceStatus() throws {
        let key = P256.Signing.PrivateKey()
        let publicKey = key.publicKey.x963Representation
        let identity = LinkitIdentity(
            deviceId: LinkitDeviceId.fromPublicKey(publicKey),
            publicKey: publicKey.base64EncodedString(),
            privateKey: key
        )
        let receiver = try MockAndroidReceiver(macIdentity: identity)
        defer { receiver.stop() }

        let target = TrustedDevice(
            deviceId: "android-device",
            deviceName: "Pixel",
            platform: "android",
            publicKey: "unused",
            pairedAt: Date().iso8601(),
            lastKnownHost: "127.0.0.1",
            receivePort: receiver.port
        )

        let status = try runOffMain {
            try OutgoingTransferClient(identity: identity, logger: LinkitLogger()).status(of: target)
        }

        XCTAssertEqual(status.deviceId, "android-device")
        XCTAssertEqual(status.status, "connected")
        XCTAssertEqual(status.batteryPercent, 77)
    }
}

private final class MockAndroidReceiver {
    let port: UInt16
    private let socketFD: Int32
    private let queue = DispatchQueue(label: "linkit.mock.android.receiver")
    private var stopped = false
    private let lock = NSLock()
    private let macIdentity: LinkitIdentity
    private(set) var uploadedBody = Data()

    init(macIdentity: LinkitIdentity) throws {
        self.macIdentity = macIdentity
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        socketFD = fd
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE) }
        guard listen(fd, 8) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        port = UInt16(bigEndian: bound.sin_port)

        queue.async { self.acceptLoop() }
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        close(socketFD)
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let isStopped = stopped
            lock.unlock()
            if isStopped { return }

            let fd = accept(socketFD, nil, nil)
            if fd < 0 { return }
            handle(fd)
            close(fd)
        }
    }

    private func handle(_ fd: Int32) {
        do {
            let request = try readRequest(fd)
            switch (request.method, request.path) {
            case ("POST", "/v1/transfers"):
                XCTAssertTrue(try verifyControlSignature(request))
                try writeJSON(fd, status: 201, json: """
                {
                  "transferId":"tr_mock",
                  "status":"created",
                  "clientDeviceId":"mac",
                  "files":[{
                    "index":0,
                    "name":"linkit-outgoing.txt",
                    "safeName":"linkit-outgoing.txt",
                    "size":14,
                    "mimeType":null,
                    "status":"created",
                    "uploadUrl":"/v1/transfers/tr_mock/files/0",
                    "uploadToken":"upload-token",
                    "uploadTokenExpiresAt":""
                  }],
                  "uploadUrl":"/v1/transfers/tr_mock/files/0",
                  "finalizeUrl":"/v1/transfers/tr_mock/finalize",
                  "statusUrl":"/v1/transfers/tr_mock",
                  "uploadToken":"upload-token",
                  "uploadTokenExpiresAt":"",
                  "expiresAt":""
                }
                """)
            case ("PUT", "/v1/transfers/tr_mock/files/0"):
                XCTAssertEqual(request.headers["x-linkit-upload-token"], "upload-token")
                XCTAssertTrue(try verifyUploadSignature(request, transferId: "tr_mock", uploadToken: "upload-token"))
                lock.lock()
                uploadedBody = request.body
                lock.unlock()
                try writeJSON(fd, status: 200, json: "{}")
            case ("POST", "/v1/transfers/tr_mock/finalize"):
                XCTAssertTrue(try verifyControlSignature(request))
                try writeJSON(fd, status: 200, json: """
                {
                  "transferId":"tr_mock",
                  "status":"complete",
                  "files":[{
                    "index":0,
                    "name":"linkit-outgoing.txt",
                    "size":14,
                    "status":"complete",
                    "savedPath":"Downloads/Linkit Drop/linkit-outgoing.txt",
                    "bytesReceived":14,
                    "sha256":"\(SHA256.hash(data: Data("hello android\n".utf8)).linkitHex)",
                    "error":null
                  }],
                  "savedPath":"Downloads/Linkit Drop/linkit-outgoing.txt",
                  "bytesReceived":14,
                  "sha256":"\(SHA256.hash(data: Data("hello android\n".utf8)).linkitHex)",
                  "error":null,
                  "message":null
                }
                """)
            case ("GET", "/v1/devices/self/status"):
                XCTAssertTrue(try verifyControlSignature(request))
                try writeJSON(fd, status: 200, json: """
                {
                  "protocolVersion":1,
                  "deviceId":"android-device",
                  "deviceName":"Pixel",
                  "platform":"android",
                  "status":"connected",
                  "receivePort":52718,
                  "batteryPercent":77
                }
                """)
            default:
                try writeJSON(fd, status: 404, json: #"{"error":"not_found","message":"not found"}"#)
            }
        } catch {
            try? writeJSON(fd, status: 500, json: #"{"error":"internal_error","message":"test server error"}"#)
        }
    }

    private func readRequest(_ fd: Int32) throws -> MockRequest {
        let delimiter = Data([13, 10, 13, 10])
        var buffer = Data()
        var temp = [UInt8](repeating: 0, count: 8192)
        while buffer.range(of: delimiter) == nil {
            let count = read(fd, &temp, temp.count)
            if count <= 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            buffer.append(temp, count: count)
        }
        let range = buffer.range(of: delimiter)!
        let headerData = buffer[..<range.lowerBound]
        var body = Data(buffer[range.upperBound...])
        let headerText = String(data: headerData, encoding: .utf8)!
        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ").map(String.init)
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        while body.count < contentLength {
            let count = read(fd, &temp, min(temp.count, contentLength - body.count))
            if count <= 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            body.append(temp, count: count)
        }
        return MockRequest(method: requestLine[0], path: requestLine[1], headers: headers, contentLength: contentLength, body: body)
    }

    private func verifyControlSignature(_ request: MockRequest) throws -> Bool {
        let bodyHash = SHA256.hash(data: request.body).linkitHex
        let canonical = SignedRequestVerifier.canonicalString(
            method: request.method,
            path: request.path,
            timestamp: request.headers["x-linkit-timestamp"] ?? "",
            nonce: request.headers["x-linkit-nonce"] ?? "",
            bodyHash: bodyHash
        )
        return try verifySignature(request, canonical: canonical)
    }

    private func verifyUploadSignature(_ request: MockRequest, transferId: String, uploadToken: String) throws -> Bool {
        let canonical = SignedRequestVerifier.uploadCanonicalString(
            deviceId: macIdentity.deviceId,
            transferId: transferId,
            fileIndex: 0,
            uploadToken: uploadToken,
            contentLength: Int64(request.contentLength),
            timestamp: request.headers["x-linkit-timestamp"] ?? "",
            nonce: request.headers["x-linkit-nonce"] ?? ""
        )
        return try verifySignature(request, canonical: canonical)
    }

    private func verifySignature(_ request: MockRequest, canonical: String) throws -> Bool {
        XCTAssertEqual(request.headers["x-linkit-device-id"], macIdentity.deviceId)
        guard let signatureText = request.headers["x-linkit-signature"],
              let signatureData = Data(base64Encoded: signatureText) else {
            return false
        }
        let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
        let publicKey = try P256.Signing.PublicKey(x963Representation: Data(base64Encoded: macIdentity.publicKey)!)
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return publicKey.isValidSignature(signature, for: digest)
    }

    private func writeJSON(_ fd: Int32, status: Int, json: String) throws {
        let body = Data(json.utf8)
        let head = "HTTP/1.1 \(status) OK\r\n"
            + "Content-Type: application/json; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        let response = Data(head.utf8) + body
        try response.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < response.count {
                let result = write(fd, base.advanced(by: written), response.count - written)
                if result < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                written += result
            }
        }
    }
}

private struct MockRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let contentLength: Int
    let body: Data
}

private func runOffMain<T>(_ body: @escaping () throws -> T) throws -> T {
    let queue = DispatchQueue(label: "linkit.outgoing.test.off-main")
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<T, Error>!
    queue.async {
        result = Result { try body() }
        semaphore.signal()
    }
    semaphore.wait()
    return try result.get()
}
