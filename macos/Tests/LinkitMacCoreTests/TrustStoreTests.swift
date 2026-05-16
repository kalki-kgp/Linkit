import CryptoKit
import XCTest
@testable import LinkitMacCore

final class TrustStoreTests: XCTestCase {
    func testPairingStoresAndroidReceiverAddressAndPort() throws {
        let fixture = try TrustFixture()
        defer { fixture.cleanup() }

        let phoneKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let phoneDeviceId = LinkitDeviceId.fromPublicKey(phoneKey)
        let token = fixture.pairing.currentToken().0

        _ = try fixture.pairing.pair(
            PairRequest(
                deviceId: phoneDeviceId,
                deviceName: "Pixel",
                platform: "android",
                publicKey: phoneKey.base64EncodedString(),
                pairingToken: token,
                receivePort: 52718,
                batteryPercent: 88
            ),
            remoteHost: "10.0.0.42"
        )

        let trusted = fixture.trust.trustedDevice(id: phoneDeviceId)
        XCTAssertEqual(trusted?.lastKnownHost, "10.0.0.42")
        XCTAssertEqual(trusted?.receivePort, 52718)
        XCTAssertEqual(fixture.connections.connectedDevice(id: phoneDeviceId)?.host, "10.0.0.42")
        XCTAssertEqual(fixture.connections.connectedDevice(id: phoneDeviceId)?.receivePort, 52718)
        XCTAssertEqual(fixture.connections.connectedDevice(id: phoneDeviceId)?.batteryPercent, 88)

        let updated = try fixture.trust.updateConnection(deviceId: phoneDeviceId, host: "10.0.0.43", receivePort: 52719)
        XCTAssertEqual(updated.lastKnownHost, "10.0.0.43")
        XCTAssertEqual(updated.receivePort, 52719)
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
        identity = try IdentityStore(baseFolder: base).loadOrCreate()
        trust = try TrustStore(baseFolder: base)
        connections = DeviceConnectionRegistry()
        pairing = try PairingManager(identity: identity, trustStore: trust, connections: connections, logger: LinkitLogger())
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: base)
    }
}
