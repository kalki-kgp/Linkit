import Foundation
import IOBluetooth

enum BluetoothInfo {
    static func macAddress() -> String? {
        guard let controller = IOBluetoothHostController.default() else { return nil }
        return normalize(controller.addressAsString())
    }

    static func pairedDeviceAddresses() -> [String] {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }
        return devices.compactMap { normalize($0.addressString) }
    }

    static func pairedDevice(for address: String) -> IOBluetoothDevice? {
        let normalized = normalize(address)
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return nil }
        return devices.first { normalize($0.addressString) == normalized }
    }

    /// Addresses of paired devices whose Bluetooth class major is "phone" (0x02).
    static func pairedPhoneAddresses() -> [String] {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }
        return devices
            .filter { $0.deviceClassMajor == kBluetoothDeviceClassMajorPhone }
            .compactMap { normalize($0.addressString) }
    }

    static func pairedDeviceAddress(named names: Set<String>) -> String? {
        guard !names.isEmpty,
              let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]
        else { return nil }
        let match = devices.first { device in
            guard let name = device.name?.lowercased() else { return false }
            return names.contains(name)
        }
        return normalize(match?.addressString)
    }

    static func normalize(_ address: String?) -> String? {
        guard let address else { return nil }
        // macOS reports addresses as "7c-f0-e5-b5-d4-f4"; Android as
        // "7C:F0:E5:B5:D4:F4". Strip separators and rebuild canonical form.
        let hex = address.uppercased().filter(\.isHexDigit)
        guard hex.count == 12 else { return nil }
        var parts: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            parts.append(String(hex[index..<next]))
            index = next
        }
        return parts.joined(separator: ":")
    }
}
