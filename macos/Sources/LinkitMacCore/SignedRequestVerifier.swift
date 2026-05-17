import CryptoKit
import Foundation

final class SignedRequestVerifier {
    private let trustStore: TrustStore
    private let logger: LinkitLogger
    private let nonceCache = NonceCache(ttl: 120)

    init(trustStore: TrustStore, logger: LinkitLogger) {
        self.trustStore = trustStore
        self.logger = logger
    }

    func verify(request: HTTPRequest, body: Data) throws -> String {
        let material = try signingMaterial(from: request)

        let bodyHash = SHA256.hash(data: body).linkitHex
        let canonical = SignedRequestVerifier.canonicalString(
            method: request.method,
            path: request.path,
            timestamp: material.timestampText,
            nonce: material.nonce,
            bodyHash: bodyHash
        )
        let digest = SHA256.hash(data: Data(canonical.utf8))
        guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: material.signatureData),
              material.publicKey.isValidSignature(signature, for: digest) else {
            logger.error("signature verification failed deviceId=\(material.deviceId) path=\(request.path)")
            throw HTTPFailure.unauthorized("invalid_signature", "Signed request signature is invalid")
        }
        guard nonceCache.insert(deviceId: material.deviceId, nonce: material.nonce) else {
            throw HTTPFailure.unauthorized("nonce_replay", "Signed request nonce was already used")
        }

        return material.deviceId
    }

    func verifyUpload(request: HTTPRequest, transferId: String, fileIndex: Int, uploadToken: String, contentLength: Int64) throws -> String {
        let material = try signingMaterial(from: request)
        let canonical = SignedRequestVerifier.uploadCanonicalString(
            deviceId: material.deviceId,
            transferId: transferId,
            fileIndex: fileIndex,
            uploadToken: uploadToken,
            contentLength: contentLength,
            timestamp: material.timestampText,
            nonce: material.nonce
        )
        let digest = SHA256.hash(data: Data(canonical.utf8))
        guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: material.signatureData),
              material.publicKey.isValidSignature(signature, for: digest) else {
            logger.error("upload signature verification failed deviceId=\(material.deviceId) transferId=\(transferId)")
            throw HTTPFailure.unauthorized("invalid_upload_signature", "Upload signature is invalid")
        }
        guard nonceCache.insert(deviceId: material.deviceId, nonce: material.nonce) else {
            throw HTTPFailure.unauthorized("nonce_replay", "Signed request nonce was already used")
        }

        return material.deviceId
    }

    static func canonicalString(method: String, path: String, timestamp: String, nonce: String, bodyHash: String) -> String {
        [
            method.uppercased(),
            path,
            timestamp,
            nonce,
            bodyHash.lowercased()
        ].joined(separator: "\n")
    }

    static func uploadCanonicalString(
        deviceId: String,
        transferId: String,
        fileIndex: Int,
        uploadToken: String,
        contentLength: Int64,
        timestamp: String,
        nonce: String
    ) -> String {
        [
            "UPLOAD",
            deviceId,
            transferId,
            "\(fileIndex)",
            uploadToken,
            "\(contentLength)",
            timestamp,
            nonce
        ].joined(separator: "\n")
    }

    private func signingMaterial(from request: HTTPRequest) throws -> SigningMaterial {
        guard let deviceId = request.headers["x-linkit-device-id"], !deviceId.isEmpty else {
            throw HTTPFailure.unauthorized("missing_signature", "Signed request is required")
        }
        guard let timestampText = request.headers["x-linkit-timestamp"],
              let timestampMillis = Int64(timestampText) else {
            throw HTTPFailure.unauthorized("invalid_timestamp", "Signed request timestamp is invalid")
        }
        guard let nonce = request.headers["x-linkit-nonce"], !nonce.isEmpty else {
            throw HTTPFailure.unauthorized("missing_nonce", "Signed request nonce is required")
        }
        guard let signatureText = request.headers["x-linkit-signature"],
              let signatureData = Data(base64Encoded: signatureText) else {
            throw HTTPFailure.unauthorized("invalid_signature", "Signed request signature is invalid")
        }

        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
        guard abs(nowMillis - timestampMillis) <= 60_000 else {
            throw HTTPFailure.unauthorized("clock_skew", "Signed request timestamp is outside tolerance")
        }

        guard let trusted = trustStore.trustedDevice(id: deviceId),
              let publicKeyData = Data(base64Encoded: trusted.publicKey),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyData) else {
            throw HTTPFailure.unauthorized("unknown_device", "Device is not paired")
        }

        return SigningMaterial(
            deviceId: deviceId,
            timestampText: timestampText,
            nonce: nonce,
            signatureData: signatureData,
            publicKey: publicKey
        )
    }
}

private struct SigningMaterial {
    let deviceId: String
    let timestampText: String
    let nonce: String
    let signatureData: Data
    let publicKey: P256.Signing.PublicKey
}

private final class NonceCache {
    private let lock = NSLock()
    private let ttl: TimeInterval
    private let maxEntries: Int
    private var entries: [String: Date] = [:]

    init(ttl: TimeInterval, maxEntries: Int = 4096) {
        self.ttl = ttl
        self.maxEntries = maxEntries
    }

    func insert(deviceId: String, nonce: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        entries = entries.filter { $0.value > now }
        let key = "\(deviceId):\(nonce)"
        guard entries[key] == nil else { return false }
        if entries.count >= maxEntries {
            let evictCount = entries.count - maxEntries + 1
            for expiredKey in entries.sorted(by: { $0.value < $1.value }).prefix(evictCount).map(\.key) {
                entries.removeValue(forKey: expiredKey)
            }
        }
        entries[key] = now.addingTimeInterval(ttl)
        return true
    }
}
