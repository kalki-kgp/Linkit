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
        guard let deviceId = request.headers["x-linkit-device-id"], !deviceId.isEmpty else {
            throw HTTPFailure.unauthorized("missing_signature", "Signed control request is required")
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
        guard let trusted = trustStore.trustedDevice(id: deviceId),
              let publicKeyData = Data(base64Encoded: trusted.publicKey),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyData) else {
            throw HTTPFailure.unauthorized("unknown_device", "Device is not paired")
        }

        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
        guard abs(nowMillis - timestampMillis) <= 60_000 else {
            throw HTTPFailure.unauthorized("clock_skew", "Signed request timestamp is outside tolerance")
        }

        let bodyHash = SHA256.hash(data: body).linkitHex
        let canonical = SignedRequestVerifier.canonicalString(
            method: request.method,
            path: request.path,
            timestamp: timestampText,
            nonce: nonce,
            bodyHash: bodyHash
        )
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
        guard publicKey.isValidSignature(signature, for: digest) else {
            logger.error("signature verification failed deviceId=\(deviceId) path=\(request.path)")
            throw HTTPFailure.unauthorized("invalid_signature", "Signed request signature is invalid")
        }
        guard nonceCache.insert(deviceId: deviceId, nonce: nonce) else {
            throw HTTPFailure.unauthorized("nonce_replay", "Signed request nonce was already used")
        }

        return deviceId
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
}

private final class NonceCache {
    private let lock = NSLock()
    private let ttl: TimeInterval
    private var entries: [String: Date] = [:]

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    func insert(deviceId: String, nonce: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        entries = entries.filter { $0.value > now }
        let key = "\(deviceId):\(nonce)"
        guard entries[key] == nil else { return false }
        entries[key] = now.addingTimeInterval(ttl)
        return true
    }
}
