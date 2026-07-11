import CryptoKit
import XCTest
@testable import LinkitMacCore

final class FeatureStatusTests: XCTestCase {
    func testFeatureStatusJSONRoundTrip() throws {
        let features = [
            FeatureStatus(id: MacFeatureID.clipboardSync, title: "Clipboard sync", state: .on, detail: "on"),
            FeatureStatus(id: MacFeatureID.transferNotifications, title: "Transfer notifications", state: .attention, detail: "grant"),
            FeatureStatus(id: MacFeatureID.launchAtLogin, title: "Launch at login", state: .off, detail: "off"),
            FeatureStatus(id: MacFeatureID.receiver, title: "Receiver", state: .unsupported, detail: "n/a")
        ]
        let data = try JSONEncoder().encode(features)
        let decoded = try JSONDecoder().decode([FeatureStatus].self, from: data)
        XCTAssertEqual(decoded, features)
    }

    func testFeatureStateDecodesFromWireString() throws {
        let json = #"[{"id":"clipboard_sync","title":"Clipboard sync","state":"attention","detail":"x"}]"#
        let decoded = try JSONDecoder().decode([FeatureStatus].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.first?.state, .attention)
    }

    func testConnectedDevicePreservesReportedFeaturesAcrossRefresh() throws {
        let connections = DeviceConnectionRegistry()
        let phoneKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let deviceId = LinkitDeviceId.fromPublicKey(phoneKey)
        let trusted = TrustedDevice(
            deviceId: deviceId,
            deviceName: "Pixel",
            platform: "android",
            publicKey: phoneKey.base64EncodedString(),
            pairedAt: Date().iso8601(),
            lastKnownHost: "10.0.0.42",
            receivePort: 52718
        )
        let reported = [FeatureStatus(id: "notification_mirror", title: "Notification mirroring", state: .attention, detail: "not receiving")]

        _ = connections.markConnected(device: trusted, host: "10.0.0.42", receivePort: 52718, batteryPercent: 50, features: reported)
        XCTAssertEqual(connections.connectedDevice(id: deviceId)?.features, reported)

        // A status refresh with no features must keep the previously reported ones.
        let noFeatures: [FeatureStatus]? = nil
        let refreshed = connections.refreshStatus(deviceId: deviceId, batteryPercent: 60, features: noFeatures)
        XCTAssertEqual(refreshed?.features, reported)
    }
}
