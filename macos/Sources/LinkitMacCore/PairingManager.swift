import Foundation

final class PairingManager {
    private let identity: LinkitIdentity
    private let trustStore: TrustStore
    private let logger: LinkitLogger
    private let lock = NSLock()
    private var token: String
    private var expiresAt: Date

    init(identity: LinkitIdentity, trustStore: TrustStore, logger: LinkitLogger) throws {
        self.identity = identity
        self.trustStore = trustStore
        self.logger = logger
        self.token = try LinkitRandom.token(byteCount: 18)
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
        let (token, expiresAt) = currentToken()
        return PairingPayload(
            v: 1,
            deviceId: identity.deviceId,
            deviceName: Host.current().localizedName ?? "Linkit Mac",
            platform: "macos",
            ip: ip,
            port: port,
            publicKey: identity.publicKey,
            pairingToken: token,
            pairingTokenExpiresAt: expiresAt.iso8601()
        )
    }

    func pair(_ request: PairRequest) throws -> PairResponse {
        let expected = currentToken()
        guard Date() <= expected.1 else {
            throw HTTPFailure.unauthorized("pairing_token_expired", "Pairing token expired")
        }
        guard request.pairingToken == expected.0 else {
            throw HTTPFailure.unauthorized("pairing_token_rejected", "Pairing token was not accepted")
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

        let trusted = TrustedDevice(
            deviceId: request.deviceId,
            deviceName: request.deviceName,
            platform: request.platform,
            publicKey: request.publicKey,
            pairedAt: Date().iso8601()
        )
        try trustStore.add(trusted)
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
        expiresAt = Date().addingTimeInterval(2 * 60)
        logger.info("rotated pairing token expiresAt=\(expiresAt.iso8601())")
    }
}
