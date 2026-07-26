import XCTest
@testable import LinkitMacCore

final class MacSystemStatusTests: XCTestCase {
    func testRSSIBucketsCoverTheBoundaries() {
        XCTAssertEqual(MacSystemStatusReader.quality(forRSSI: -30), "excellent")
        XCTAssertEqual(MacSystemStatusReader.quality(forRSSI: -50), "excellent")
        XCTAssertEqual(MacSystemStatusReader.quality(forRSSI: -51), "good")
        XCTAssertEqual(MacSystemStatusReader.quality(forRSSI: -65), "good")
        XCTAssertEqual(MacSystemStatusReader.quality(forRSSI: -66), "fair")
        XCTAssertEqual(MacSystemStatusReader.quality(forRSSI: -75), "fair")
        XCTAssertEqual(MacSystemStatusReader.quality(forRSSI: -76), "weak")
        XCTAssertEqual(MacSystemStatusReader.quality(forRSSI: -95), "weak")
    }

    func testReaderReportsThisMacWithoutPrompting() {
        // Nothing here needs an entitlement or user consent, so it must produce a usable answer
        // on any Mac: a desktop simply has no battery, and an Ethernet-only Mac has no RSSI.
        let status = MacSystemStatusReader.current(
            doNotDisturb: true,
            dropFolder: FileManager.default.homeDirectoryForCurrentUser
        )
        XCTAssertTrue(status.doNotDisturb)
        XCTAssertEqual(status.osVersion?.hasPrefix("macOS "), true)
        XCTAssertNotNil(status.freeDiskBytes)
        XCTAssertGreaterThan(status.freeDiskBytes ?? 0, 0)
        if let percent = status.batteryPercent {
            XCTAssertTrue((0...100).contains(percent))
        }
        if let rssi = status.wifiRssi {
            XCTAssertLessThan(rssi, 0)
            XCTAssertNotNil(status.wifiQuality)
        }
    }

    /// Android reads these keys by name off the registration response, so the JSON shape is part
    /// of the wire contract — not just an internal detail of the Swift struct.
    func testRegistrationResponseCarriesMacStatusUnderStableKeys() throws {
        let status = MacSystemStatus(
            batteryPercent: 45,
            isCharging: true,
            powerSource: "ac",
            minutesToFull: 116,
            minutesToEmpty: nil,
            lowPowerMode: true,
            networkKind: "wifi",
            wifiRssi: -62,
            wifiQuality: "good",
            freeDiskBytes: 98_087_980_416,
            totalDiskBytes: 245_107_195_904,
            doNotDisturb: false,
            osVersion: "macOS 26.4"
        )
        let response = DeviceConnectionResponse(
            deviceId: "phone-a",
            deviceName: "Pixel",
            platform: "android",
            status: "connected",
            host: "10.0.0.42",
            receivePort: 52719,
            batteryPercent: 80,
            connectedAt: nil,
            lastSeenAt: nil,
            features: nil,
            mac: status
        )

        let data = try JSONEncoder().encode(response)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let mac = try XCTUnwrap(json["mac"] as? [String: Any])

        XCTAssertEqual(mac["batteryPercent"] as? Int, 45)
        XCTAssertEqual(mac["isCharging"] as? Bool, true)
        XCTAssertEqual(mac["powerSource"] as? String, "ac")
        XCTAssertEqual(mac["minutesToFull"] as? Int, 116)
        XCTAssertEqual(mac["lowPowerMode"] as? Bool, true)
        XCTAssertEqual(mac["networkKind"] as? String, "wifi")
        XCTAssertEqual(mac["wifiQuality"] as? String, "good")
        XCTAssertEqual(mac["freeDiskBytes"] as? Int64, 98_087_980_416)
        XCTAssertEqual(mac["doNotDisturb"] as? Bool, false)
        XCTAssertEqual(mac["osVersion"] as? String, "macOS 26.4")
        // Absent rather than null, which is what lets the phone tell "no reading" from "zero".
        XCTAssertNil(mac["minutesToEmpty"])

        XCTAssertEqual(try JSONDecoder().decode(DeviceConnectionResponse.self, from: data), response)
    }

    /// An older Mac sends no `mac` object at all; decoding must still succeed so a version-skewed
    /// pair keeps working.
    func testRegistrationResponseDecodesWithoutMacStatus() throws {
        let json = """
        {"deviceId":"phone-a","deviceName":"Pixel","platform":"android","status":"connected"}
        """
        let response = try JSONDecoder().decode(DeviceConnectionResponse.self, from: Data(json.utf8))
        XCTAssertNil(response.mac)
        XCTAssertNil(response.features)
    }
}
