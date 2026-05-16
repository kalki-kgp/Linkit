import CryptoKit
import Foundation

public struct LinkitIdentity {
    public let deviceId: String
    public let publicKey: String
    let privateKey: P256.Signing.PrivateKey
}

public struct TrustedDevice: Codable, Equatable {
    public let deviceId: String
    public let deviceName: String
    public let platform: String
    public let publicKey: String
    public let pairedAt: String
    public let lastKnownHost: String?
    public let receivePort: UInt16?
}

final class IdentityStore {
    private let fileURL: URL

    init(baseFolder: URL = LinkitPaths.applicationSupport) throws {
        try FileManager.default.createDirectory(at: baseFolder, withIntermediateDirectories: true)
        self.fileURL = baseFolder.appendingPathComponent("mac-identity.p256")
    }

    func loadOrCreate() throws -> LinkitIdentity {
        let privateKey: P256.Signing.PrivateKey
        if FileManager.default.fileExists(atPath: fileURL.path) {
            privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(contentsOf: fileURL))
        } else {
            privateKey = P256.Signing.PrivateKey()
            try privateKey.rawRepresentation.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }

        let publicKey = privateKey.publicKey.x963Representation
        return LinkitIdentity(
            deviceId: LinkitDeviceId.fromPublicKey(publicKey),
            publicKey: publicKey.base64EncodedString(),
            privateKey: privateKey
        )
    }
}

final class TrustStore {
    private let lock = NSLock()
    private let fileURL: URL
    private var devices: [String: TrustedDevice] = [:]

    init(baseFolder: URL = LinkitPaths.applicationSupport) throws {
        try FileManager.default.createDirectory(at: baseFolder, withIntermediateDirectories: true)
        self.fileURL = baseFolder.appendingPathComponent("trusted-devices.json")
        try load()
    }

    func add(_ device: TrustedDevice) throws {
        lock.lock()
        defer { lock.unlock() }
        devices[device.deviceId] = device
        try saveLocked()
    }

    func updateConnection(deviceId: String, host: String, receivePort: UInt16) throws -> TrustedDevice {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = devices[deviceId] else {
            throw HTTPFailure.unauthorized("unknown_device", "Device is not paired")
        }
        let updated = TrustedDevice(
            deviceId: existing.deviceId,
            deviceName: existing.deviceName,
            platform: existing.platform,
            publicKey: existing.publicKey,
            pairedAt: existing.pairedAt,
            lastKnownHost: host,
            receivePort: receivePort
        )
        devices[deviceId] = updated
        try saveLocked()
        return updated
    }

    func trustedDevice(id: String) -> TrustedDevice? {
        lock.lock()
        defer { lock.unlock() }
        return devices[id]
    }

    func allDevices() -> [TrustedDevice] {
        lock.lock()
        defer { lock.unlock() }
        return devices.values.sorted { $0.deviceName < $1.deviceName }
    }

    private func load() throws {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            devices = [:]
            return
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode([TrustedDevice].self, from: data)
        devices = Dictionary(uniqueKeysWithValues: decoded.map { ($0.deviceId, $0) })
    }

    private func saveLocked() throws {
        let data = try JSONEncoder().encode(Array(devices.values))
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

public enum LinkitPaths {
    public static let applicationSupport: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("Linkit", isDirectory: true)
}

enum LinkitDeviceId {
    static func fromPublicKey(_ data: Data) -> String {
        SHA256.hash(data: data).linkitHex.prefix(32).lowercased()
    }
}
