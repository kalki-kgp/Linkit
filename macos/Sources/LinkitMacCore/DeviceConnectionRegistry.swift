import Foundation

public struct ConnectedDevice: Equatable {
    public let deviceId: String
    public let deviceName: String
    public let platform: String
    public let host: String
    public let receivePort: UInt16
    public let batteryPercent: Int?
    public let connectedAt: String
    public let lastSeenAt: String
}

final class DeviceConnectionRegistry {
    private let lock = NSLock()
    private var connections: [String: ConnectedDevice] = [:]

    func markConnected(
        device: TrustedDevice,
        host: String,
        receivePort: UInt16,
        batteryPercent: Int?,
        now: Date = Date()
    ) -> ConnectedDevice {
        lock.lock()
        defer { lock.unlock() }

        let previous = connections[device.deviceId]
        let connectedAt = connections[device.deviceId]?.connectedAt ?? now.iso8601()
        let connected = ConnectedDevice(
            deviceId: device.deviceId,
            deviceName: device.deviceName,
            platform: device.platform,
            host: host,
            receivePort: receivePort,
            batteryPercent: normalizedBatteryPercent(batteryPercent) ?? previous?.batteryPercent,
            connectedAt: connectedAt,
            lastSeenAt: now.iso8601()
        )
        connections[device.deviceId] = connected
        return connected
    }

    func disconnect(deviceId: String) {
        lock.lock()
        connections.removeValue(forKey: deviceId)
        lock.unlock()
    }

    func connectedDevice(id: String) -> ConnectedDevice? {
        lock.lock()
        defer { lock.unlock() }
        return connections[id]
    }

    func allConnected() -> [ConnectedDevice] {
        lock.lock()
        defer { lock.unlock() }
        return connections.values.sorted { $0.deviceName < $1.deviceName }
    }

    private func normalizedBatteryPercent(_ value: Int?) -> Int? {
        guard let value else { return nil }
        return min(100, max(0, value))
    }
}
