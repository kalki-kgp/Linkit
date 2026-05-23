import CryptoKit
import XCTest
@testable import LinkitMacCore

final class TrustStoreTests: XCTestCase {
    func testIdentityStoreKeepsStableIdentityInPrivateStore() throws {
        let keyStore = InMemoryPrivateKeyStore()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkit-identity-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let first = try IdentityStore(baseFolder: base, keyStore: keyStore).loadOrCreate()
        let second = try IdentityStore(baseFolder: base, keyStore: keyStore).loadOrCreate()

        XCTAssertEqual(first.deviceId, second.deviceId)
        XCTAssertEqual(first.publicKey, second.publicKey)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("mac-identity.p256").path))
    }

    func testIdentityStoreMigratesLegacyFileIntoPrivateStore() throws {
        let keyStore = InMemoryPrivateKeyStore()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkit-identity-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let legacyKey = P256.Signing.PrivateKey()
        let legacyFile = base.appendingPathComponent("mac-identity.p256")
        try legacyKey.rawRepresentation.write(to: legacyFile, options: [.atomic])
        let expectedDeviceId = LinkitDeviceId.fromPublicKey(legacyKey.publicKey.x963Representation)

        let identity = try IdentityStore(baseFolder: base, keyStore: keyStore).loadOrCreate()

        XCTAssertEqual(identity.deviceId, expectedDeviceId)
        XCTAssertEqual(try XCTUnwrap(keyStore.data), legacyKey.rawRepresentation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
    }

    func testPairingStoresAndroidReceiverAddressAndPort() throws {
        let fixture = try TrustFixture()
        defer { fixture.cleanup() }

        let phonePrivateKey = P256.Signing.PrivateKey()
        let phoneKey = phonePrivateKey.publicKey.x963Representation
        let phonePublicKey = phoneKey.base64EncodedString()
        let phoneDeviceId = LinkitDeviceId.fromPublicKey(phoneKey)
        let payload = fixture.pairing.pairingPayload(ip: "10.0.0.1", port: 52718)
        let signature = try pairingChallengeSignature(
            privateKey: phonePrivateKey,
            macDeviceId: fixture.identity.deviceId,
            androidDeviceId: phoneDeviceId,
            androidPublicKey: phonePublicKey,
            pairingToken: payload.pairingToken,
            challenge: payload.pairingChallenge
        )

        _ = try fixture.pairing.pair(
            PairRequest(
                deviceId: phoneDeviceId,
                deviceName: "Pixel",
                platform: "android",
                publicKey: phonePublicKey,
                pairingToken: payload.pairingToken,
                pairingChallenge: payload.pairingChallenge,
                pairingChallengeSignature: signature,
                receivePort: 52718,
                batteryPercent: 88
            ),
            remoteHost: "10.0.0.42"
        )

        let trusted = fixture.trust.trustedDevice(id: phoneDeviceId)
        XCTAssertNil(trusted?.lastKnownHost)
        XCTAssertNil(trusted?.receivePort)
        let trustedDevice = try XCTUnwrap(trusted)
        XCTAssertEqual(fixture.connections.connectedDevice(id: phoneDeviceId)?.host, "10.0.0.42")
        XCTAssertEqual(fixture.connections.connectedDevice(id: phoneDeviceId)?.receivePort, 52718)
        XCTAssertEqual(fixture.connections.connectedDevice(id: phoneDeviceId)?.batteryPercent, 88)

        _ = fixture.connections.markConnected(device: trustedDevice, host: "10.0.0.43", receivePort: 52719, batteryPercent: 77)
        let persisted = fixture.trust.trustedDevice(id: phoneDeviceId)
        XCTAssertNil(persisted?.lastKnownHost)
        XCTAssertNil(persisted?.receivePort)
    }

    func testDisconnectAndForgetDoNotMutateOtherTrust() throws {
        let fixture = try TrustFixture()
        defer { fixture.cleanup() }

        let phoneKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let phoneDeviceId = LinkitDeviceId.fromPublicKey(phoneKey)
        let trusted = TrustedDevice(
            deviceId: phoneDeviceId,
            deviceName: "Pixel",
            platform: "android",
            publicKey: phoneKey.base64EncodedString(),
            pairedAt: Date().iso8601(),
            lastKnownHost: "10.0.0.42",
            receivePort: 52718
        )
        try fixture.trust.add(trusted)
        _ = fixture.connections.markConnected(device: trusted, host: "10.0.0.42", receivePort: 52718, batteryPercent: 42)

        fixture.connections.disconnect(deviceId: phoneDeviceId)
        XCTAssertNil(fixture.connections.connectedDevice(id: phoneDeviceId))
        XCTAssertNotNil(fixture.trust.trustedDevice(id: phoneDeviceId))

        _ = try fixture.trust.remove(deviceId: phoneDeviceId)
        fixture.connections.disconnect(deviceId: phoneDeviceId)
        XCTAssertNil(fixture.trust.trustedDevice(id: phoneDeviceId))
    }

    func testBatteryPercentIsClampedAndPreservedWhenMissing() throws {
        let fixture = try TrustFixture()
        defer { fixture.cleanup() }

        let phoneKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let phoneDeviceId = LinkitDeviceId.fromPublicKey(phoneKey)
        let trusted = TrustedDevice(
            deviceId: phoneDeviceId,
            deviceName: "Pixel",
            platform: "android",
            publicKey: phoneKey.base64EncodedString(),
            pairedAt: Date().iso8601(),
            lastKnownHost: "10.0.0.42",
            receivePort: 52718
        )

        let over = fixture.connections.markConnected(device: trusted, host: "10.0.0.42", receivePort: 52718, batteryPercent: 140)
        XCTAssertEqual(over.batteryPercent, 100)

        let preserved = fixture.connections.markConnected(device: trusted, host: "10.0.0.43", receivePort: 52718, batteryPercent: nil)
        XCTAssertEqual(preserved.batteryPercent, 100)
    }

    func testPairingRejectsExpiredToken() throws {
        let fixture = try TrustFixture()
        defer { fixture.cleanup() }

        let phonePrivateKey = P256.Signing.PrivateKey()
        let phoneKey = phonePrivateKey.publicKey.x963Representation
        let phonePublicKey = phoneKey.base64EncodedString()
        let phoneDeviceId = LinkitDeviceId.fromPublicKey(phoneKey)
        let payload = fixture.pairing.pairingPayload(ip: "10.0.0.1", port: 52718)
        let signature = try pairingChallengeSignature(
            privateKey: phonePrivateKey,
            macDeviceId: fixture.identity.deviceId,
            androidDeviceId: phoneDeviceId,
            androidPublicKey: phonePublicKey,
            pairingToken: payload.pairingToken,
            challenge: payload.pairingChallenge
        )

        fixture.pairing.expirePairingMaterialForTesting()

        XCTAssertThrowsError(
            try fixture.pairing.pair(
                PairRequest(
                    deviceId: phoneDeviceId,
                    deviceName: "Pixel",
                    platform: "android",
                    publicKey: phonePublicKey,
                    pairingToken: payload.pairingToken,
                    pairingChallenge: payload.pairingChallenge,
                    pairingChallengeSignature: signature,
                    receivePort: nil,
                    batteryPercent: nil
                ),
                remoteHost: "10.0.0.42"
            )
        ) { error in
            XCTAssertEqual((error as? HTTPFailure)?.error, "pairing_token_expired")
        }
    }

    func testPairingRejectsWrongTokenUnsupportedPlatformAndDeviceMismatch() throws {
        let fixture = try TrustFixture()
        defer { fixture.cleanup() }

        let phonePrivateKey = P256.Signing.PrivateKey()
        let phoneKey = phonePrivateKey.publicKey.x963Representation
        let phonePublicKey = phoneKey.base64EncodedString()
        let phoneDeviceId = LinkitDeviceId.fromPublicKey(phoneKey)
        let payload = fixture.pairing.pairingPayload(ip: "10.0.0.1", port: 52718)
        let signature = try pairingChallengeSignature(
            privateKey: phonePrivateKey,
            macDeviceId: fixture.identity.deviceId,
            androidDeviceId: phoneDeviceId,
            androidPublicKey: phonePublicKey,
            pairingToken: payload.pairingToken,
            challenge: payload.pairingChallenge
        )

        XCTAssertThrowsError(
            try fixture.pairing.pair(
                PairRequest(
                    deviceId: phoneDeviceId,
                    deviceName: "Pixel",
                    platform: "android",
                    publicKey: phonePublicKey,
                    pairingToken: "wrong",
                    pairingChallenge: payload.pairingChallenge,
                    pairingChallengeSignature: signature,
                    receivePort: nil,
                    batteryPercent: nil
                ),
                remoteHost: "10.0.0.42"
            )
        ) { error in
            XCTAssertEqual((error as? HTTPFailure)?.error, "pairing_token_rejected")
        }

        XCTAssertThrowsError(
            try fixture.pairing.pair(
                PairRequest(
                    deviceId: phoneDeviceId,
                    deviceName: "Laptop",
                    platform: "macos",
                    publicKey: phonePublicKey,
                    pairingToken: payload.pairingToken,
                    pairingChallenge: payload.pairingChallenge,
                    pairingChallengeSignature: signature,
                    receivePort: nil,
                    batteryPercent: nil
                ),
                remoteHost: "10.0.0.42"
            )
        ) { error in
            XCTAssertEqual((error as? HTTPFailure)?.error, "unsupported_platform")
        }

        XCTAssertThrowsError(
            try fixture.pairing.pair(
                PairRequest(
                    deviceId: "not-\(phoneDeviceId)",
                    deviceName: "Pixel",
                    platform: "android",
                    publicKey: phonePublicKey,
                    pairingToken: payload.pairingToken,
                    pairingChallenge: payload.pairingChallenge,
                    pairingChallengeSignature: signature,
                    receivePort: nil,
                    batteryPercent: nil
                ),
                remoteHost: "10.0.0.42"
            )
        ) { error in
            XCTAssertEqual((error as? HTTPFailure)?.error, "device_id_mismatch")
        }
    }
}

private func pairingChallengeSignature(
    privateKey: P256.Signing.PrivateKey,
    macDeviceId: String,
    androidDeviceId: String,
    androidPublicKey: String,
    pairingToken: String,
    challenge: String
) throws -> String {
    let canonical = LinkitPairingChallenge.canonicalString(
        macDeviceId: macDeviceId,
        androidDeviceId: androidDeviceId,
        androidPublicKey: androidPublicKey,
        pairingToken: pairingToken,
        challenge: challenge
    )
    let digest = SHA256.hash(data: Data(canonical.utf8))
    return try privateKey.signature(for: digest).derRepresentation.base64EncodedString()
}

private final class TrustFixture {
    let base: URL
    let identity: LinkitIdentity
    let trust: TrustStore
    let connections: DeviceConnectionRegistry
    let pairing: PairingManager

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkit-trust-tests-\(UUID().uuidString)", isDirectory: true)
        identity = try IdentityStore(baseFolder: base, keyStore: InMemoryPrivateKeyStore()).loadOrCreate()
        trust = try TrustStore(baseFolder: base)
        connections = DeviceConnectionRegistry()
        pairing = try PairingManager(identity: identity, trustStore: trust, connections: connections, logger: LinkitLogger())
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: base)
    }
}

private final class InMemoryPrivateKeyStore: LinkitPrivateKeyStore {
    var data: Data?

    func load() throws -> Data? {
        data
    }

    func save(_ data: Data) throws {
        self.data = data
    }
}
