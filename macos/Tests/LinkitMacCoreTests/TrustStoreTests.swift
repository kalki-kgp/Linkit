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
                receivePort: 52718
            ),
            remoteHost: "10.0.0.42"
        )

        let trusted = fixture.trust.trustedDevice(id: phoneDeviceId)
        XCTAssertEqual(trusted?.lastKnownHost, "10.0.0.42")
        XCTAssertEqual(trusted?.receivePort, 52718)

        let updated = try fixture.trust.updateConnection(deviceId: phoneDeviceId, host: "10.0.0.43", receivePort: 52719)
        XCTAssertEqual(updated.lastKnownHost, "10.0.0.43")
        XCTAssertEqual(updated.receivePort, 52719)
    }
}

private final class TrustFixture {
    let base: URL
    let identity: LinkitIdentity
    let trust: TrustStore
    let pairing: PairingManager

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkit-trust-tests-\(UUID().uuidString)", isDirectory: true)
        identity = try IdentityStore(baseFolder: base).loadOrCreate()
        trust = try TrustStore(baseFolder: base)
        pairing = try PairingManager(identity: identity, trustStore: trust, logger: LinkitLogger())
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: base)
    }
}
