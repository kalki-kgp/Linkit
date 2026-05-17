import CryptoKit
import XCTest
@testable import LinkitMacCore

final class SignedRequestVerifierTests: XCTestCase {
    func testRejectsBadSignature() throws {
        let fixture = try SignedVerifierFixture()
        defer { fixture.cleanup() }

        let request = try fixture.signedRequest(path: "/v1/history", body: Data(), extraHeaders: ["x-linkit-signature": "bad"])

        XCTAssertThrowsError(try fixture.verifier.verify(request: request, body: Data())) { error in
            XCTAssertEqual((error as? HTTPFailure)?.error, "invalid_signature")
        }
    }

    func testRejectsReplayNonce() throws {
        let fixture = try SignedVerifierFixture()
        defer { fixture.cleanup() }

        let request = try fixture.signedRequest(path: "/v1/history", body: Data())
        XCTAssertEqual(try fixture.verifier.verify(request: request, body: Data()), fixture.deviceId)
        XCTAssertThrowsError(try fixture.verifier.verify(request: request, body: Data())) { error in
            XCTAssertEqual((error as? HTTPFailure)?.error, "nonce_replay")
        }
    }

    func testRejectsClockSkew() throws {
        let fixture = try SignedVerifierFixture()
        defer { fixture.cleanup() }

        let timestamp = String(Int64(Date().addingTimeInterval(-120).timeIntervalSince1970 * 1000))
        let request = try fixture.signedRequest(path: "/v1/history", body: Data(), timestamp: timestamp)

        XCTAssertThrowsError(try fixture.verifier.verify(request: request, body: Data())) { error in
            XCTAssertEqual((error as? HTTPFailure)?.error, "clock_skew")
        }
    }

    func testRejectsUnknownDeviceBeforeSignatureTrust() throws {
        let fixture = try SignedVerifierFixture(addTrustedDevice: false)
        defer { fixture.cleanup() }

        let request = try fixture.signedRequest(path: "/v1/history", body: Data())

        XCTAssertThrowsError(try fixture.verifier.verify(request: request, body: Data())) { error in
            XCTAssertEqual((error as? HTTPFailure)?.error, "unknown_device")
        }
    }

    func testVerifiesSignedUploadTuple() throws {
        let fixture = try SignedVerifierFixture()
        defer { fixture.cleanup() }

        let request = try fixture.signedUploadRequest(
            transferId: "tr_test",
            uploadToken: "upload-token",
            contentLength: 42
        )

        XCTAssertEqual(
            try fixture.verifier.verifyUpload(
                request: request,
                transferId: "tr_test",
                fileIndex: 0,
                uploadToken: "upload-token",
                contentLength: 42
            ),
            fixture.deviceId
        )
    }
}

private final class SignedVerifierFixture {
    let base: URL
    let key = P256.Signing.PrivateKey()
    let deviceId: String
    let publicKey: String
    let trustStore: TrustStore
    let verifier: SignedRequestVerifier

    init(addTrustedDevice: Bool = true) throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkit-signed-verifier-\(UUID().uuidString)", isDirectory: true)
        let publicKeyData = key.publicKey.x963Representation
        deviceId = LinkitDeviceId.fromPublicKey(publicKeyData)
        publicKey = publicKeyData.base64EncodedString()
        trustStore = try TrustStore(baseFolder: base)
        if addTrustedDevice {
            try trustStore.add(
                TrustedDevice(
                    deviceId: deviceId,
                    deviceName: "Pixel",
                    platform: "android",
                    publicKey: publicKey,
                    pairedAt: Date().iso8601(),
                    lastKnownHost: nil,
                    receivePort: nil
                )
            )
        }
        verifier = try SignedRequestVerifier(trustStore: trustStore, logger: LinkitLogger())
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: base)
    }

    func signedRequest(
        path: String,
        body: Data,
        timestamp: String? = nil,
        nonce: String = UUID().uuidString,
        extraHeaders: [String: String] = [:]
    ) throws -> HTTPRequest {
        let timestamp = timestamp ?? String(Int64(Date().timeIntervalSince1970 * 1000))
        let bodyHash = SHA256.hash(data: body).linkitHex
        let canonical = SignedRequestVerifier.canonicalString(
            method: "GET",
            path: path,
            timestamp: timestamp,
            nonce: nonce,
            bodyHash: bodyHash
        )
        return try request(path: path, timestamp: timestamp, nonce: nonce, canonical: canonical, extraHeaders: extraHeaders)
    }

    func signedUploadRequest(transferId: String, uploadToken: String, contentLength: Int64) throws -> HTTPRequest {
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        let nonce = UUID().uuidString
        let canonical = SignedRequestVerifier.uploadCanonicalString(
            deviceId: deviceId,
            transferId: transferId,
            fileIndex: 0,
            uploadToken: uploadToken,
            contentLength: contentLength,
            timestamp: timestamp,
            nonce: nonce
        )
        return try request(
            path: "/v1/transfers/\(transferId)/files/0",
            timestamp: timestamp,
            nonce: nonce,
            canonical: canonical,
            extraHeaders: [
                "x-linkit-upload-token": uploadToken,
                "x-linkit-client-device-id": deviceId
            ]
        )
    }

    private func request(
        path: String,
        timestamp: String,
        nonce: String,
        canonical: String,
        extraHeaders: [String: String] = [:]
    ) throws -> HTTPRequest {
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let signature = try key.signature(for: digest).derRepresentation.base64EncodedString()
        var headers = [
            "x-linkit-device-id": deviceId,
            "x-linkit-timestamp": timestamp,
            "x-linkit-nonce": nonce,
            "x-linkit-signature": signature
        ]
        for (key, value) in extraHeaders {
            headers[key] = value
        }
        return HTTPRequest(
            method: "GET",
            target: path,
            path: path,
            headers: headers,
            contentLength: 0,
            bodyRemainder: Data(),
            remoteHost: "127.0.0.1"
        )
    }
}
