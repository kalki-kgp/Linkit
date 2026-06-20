import CryptoKit
import Foundation

final class PairingManager {
    private let identity: LinkitIdentity
    private let trustStore: TrustStore
    private let connections: DeviceConnectionRegistry
    private let logger: LinkitLogger
    private let lock = NSLock()
    private var token: String
    private var challenge: String
    private var secret: String
    private var expiresAt: Date

    init(identity: LinkitIdentity, trustStore: TrustStore, connections: DeviceConnectionRegistry, logger: LinkitLogger) throws {
        self.identity = identity
        self.trustStore = trustStore
        self.connections = connections
        self.logger = logger
        self.token = try LinkitRandom.token(byteCount: 18)
        self.challenge = try LinkitRandom.token(byteCount: 32)
        self.secret = PairingManager.generateSecret()
        self.expiresAt = Date().addingTimeInterval(2 * 60)
    }

    func currentToken() -> (String, Date) {
        lock.lock()
        defer { lock.unlock() }
        if Date() > expiresAt {
            rotateLocked()
        }
        return (token, expiresAt)
    }

    func rotate() {
        lock.lock()
        defer { lock.unlock() }
        rotateLocked()
    }

    func pairingPayload(ip: String, port: UInt16) -> PairingPayload {
        let (token, challenge, secret, expiresAt) = pairingMaterialRotatingIfExpired()
        return PairingPayload(
            v: 1,
            deviceId: identity.deviceId,
            deviceName: Host.current().localizedName ?? "Linkit Mac",
            platform: "macos",
            ip: ip,
            port: port,
            publicKey: identity.publicKey,
            pairingToken: token,
            pairingChallenge: challenge,
            pairingTokenExpiresAt: expiresAt.iso8601(),
            pairingSecret: secret
        )
    }

    func pair(_ request: PairRequest, remoteHost: String?) throws -> PairResponse {
        let expected = pairingMaterialForVerification()
        guard Date() <= expected.expiresAt else {
            throw HTTPFailure.unauthorized("pairing_token_expired", "Pairing token expired")
        }
        guard constantTimeEqual(request.pairingToken, expected.token) else {
            throw HTTPFailure.unauthorized("pairing_token_rejected", "Pairing token was not accepted")
        }
        if let suppliedChallenge = request.pairingChallenge, suppliedChallenge != expected.challenge {
            throw HTTPFailure.unauthorized("pairing_challenge_rejected", "Pairing challenge was not accepted")
        }
        guard request.platform.lowercased() == "android" else {
            throw HTTPFailure.badRequest("unsupported_platform", "Only Android senders can pair with this MVP")
        }
        guard let publicKeyData = Data(base64Encoded: request.publicKey), !publicKeyData.isEmpty else {
            throw HTTPFailure.badRequest("invalid_public_key", "Device public key is invalid")
        }
        guard LinkitDeviceId.fromPublicKey(publicKeyData) == request.deviceId else {
            throw HTTPFailure.badRequest("device_id_mismatch", "Device id does not match public key")
        }
        guard let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyData) else {
            throw HTTPFailure.badRequest("invalid_public_key", "Device public key is invalid")
        }
        guard let signatureText = request.pairingChallengeSignature,
              let signatureData = Data(base64Encoded: signatureText),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData) else {
            throw HTTPFailure.unauthorized("missing_pairing_challenge_signature", "Pairing challenge signature is required")
        }
        let canonical = LinkitPairingChallenge.canonicalString(
            macDeviceId: identity.deviceId,
            androidDeviceId: request.deviceId,
            androidPublicKey: request.publicKey,
            pairingToken: expected.token,
            challenge: expected.challenge
        )
        let digest = SHA256.hash(data: Data(canonical.utf8))
        guard publicKey.isValidSignature(signature, for: digest) else {
            throw HTTPFailure.unauthorized("invalid_pairing_challenge_signature", "Pairing challenge signature is invalid")
        }

        let trusted = TrustedDevice(
            deviceId: request.deviceId,
            deviceName: request.deviceName,
            platform: request.platform,
            publicKey: request.publicKey,
            pairedAt: Date().iso8601(),
            lastKnownHost: nil,
            receivePort: nil,
            pairingSecret: expected.secret
        )
        try trustStore.add(trusted)
        if let remoteHost, let receivePort = request.receivePort {
            _ = connections.markConnected(
                device: trusted,
                host: remoteHost,
                receivePort: receivePort,
                batteryPercent: request.batteryPercent
            )
        }
        rotate()
        logger.info("paired trusted device id=\(trusted.deviceId) name=\(trusted.deviceName)")

        return PairResponse(
            protocolVersion: 1,
            deviceId: identity.deviceId,
            deviceName: Host.current().localizedName ?? "Linkit Mac",
            platform: "macos",
            publicKey: identity.publicKey,
            trustedDeviceId: trusted.deviceId,
            status: "paired"
        )
    }

    private func rotateLocked() {
        token = (try? LinkitRandom.token(byteCount: 18)) ?? UUID().uuidString
        challenge = (try? LinkitRandom.token(byteCount: 32)) ?? UUID().uuidString
        secret = PairingManager.generateSecret()
        expiresAt = Date().addingTimeInterval(2 * 60)
        logger.info("rotated pairing token expiresAt=\(expiresAt.iso8601())")
    }

    /// 32 random bytes as standard base64 — the per-pairing AES key carried in the QR.
    private static func generateSecret() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
    }

    private func pairingMaterialRotatingIfExpired() -> (token: String, challenge: String, secret: String, expiresAt: Date) {
        lock.lock()
        defer { lock.unlock() }
        if Date() > expiresAt {
            rotateLocked()
        }
        return (token, challenge, secret, expiresAt)
    }

    private func pairingMaterialForVerification() -> (token: String, challenge: String, secret: String, expiresAt: Date) {
        lock.lock()
        defer { lock.unlock() }
        return (token, challenge, secret, expiresAt)
    }

    #if DEBUG
    func expirePairingMaterialForTesting() {
        lock.lock()
        defer { lock.unlock() }
        expiresAt = Date().addingTimeInterval(-1)
    }
    #endif
}

private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let lhsBytes = Array(lhs.utf8)
    let rhsBytes = Array(rhs.utf8)
    var diff = lhsBytes.count ^ rhsBytes.count
    for index in 0..<max(lhsBytes.count, rhsBytes.count) {
        let lhsByte = index < lhsBytes.count ? lhsBytes[index] : 0
        let rhsByte = index < rhsBytes.count ? rhsBytes[index] : 0
        diff |= Int(lhsByte ^ rhsByte)
    }
    return diff == 0
}
