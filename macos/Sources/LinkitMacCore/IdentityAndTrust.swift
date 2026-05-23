import CryptoKit
import Foundation
import Security

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
    private let keyStore: LinkitPrivateKeyStore

    init(baseFolder: URL = LinkitPaths.applicationSupport, keyStore: LinkitPrivateKeyStore = KeychainPrivateKeyStore()) throws {
        try FileManager.default.createDirectory(at: baseFolder, withIntermediateDirectories: true)
        self.fileURL = baseFolder.appendingPathComponent("mac-identity.p256")
        self.keyStore = keyStore
    }

    func loadOrCreate() throws -> LinkitIdentity {
        let rawKey: Data
        if let storedKey = try keyStore.load() {
            rawKey = storedKey
        } else if FileManager.default.fileExists(atPath: fileURL.path) {
            rawKey = try Data(contentsOf: fileURL)
            _ = try P256.Signing.PrivateKey(rawRepresentation: rawKey)
            try keyStore.save(rawKey)
            try FileManager.default.removeItem(at: fileURL)
        } else {
            rawKey = P256.Signing.PrivateKey().rawRepresentation
            try keyStore.save(rawKey)
        }

        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: rawKey)
        let publicKey = privateKey.publicKey.x963Representation
        return LinkitIdentity(
            deviceId: LinkitDeviceId.fromPublicKey(publicKey),
            publicKey: publicKey.base64EncodedString(),
            privateKey: privateKey
        )
    }
}

protocol LinkitPrivateKeyStore {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

enum LinkitKeychainError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain operation failed with status \(status)"
        }
    }
}

final class KeychainPrivateKeyStore: LinkitPrivateKeyStore {
    private let service = "tech.kalkikgp.Linkit"
    private let account = "mac-identity.p256"

    func load() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw LinkitKeychainError.unexpectedStatus(status)
        }
        return result as? Data
    }

    func save(_ data: Data) throws {
        var query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw LinkitKeychainError.unexpectedStatus(updateStatus)
        }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw LinkitKeychainError.unexpectedStatus(addStatus)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
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
        do {
            devices[device.deviceId] = device
            try saveLocked()
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        postDeviceChange()
    }

    func remove(deviceId: String) throws -> TrustedDevice? {
        lock.lock()
        let removed: TrustedDevice?
        do {
            removed = devices.removeValue(forKey: deviceId)
            try saveLocked()
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        if removed != nil {
            postDeviceChange()
        }
        return removed
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

    private func postDeviceChange() {
        NotificationCenter.default.post(name: .linkitDevicesDidChange, object: nil)
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

enum LinkitPairingChallenge {
    static func canonicalString(
        macDeviceId: String,
        androidDeviceId: String,
        androidPublicKey: String,
        pairingToken: String,
        challenge: String
    ) -> String {
        [
            "LINKIT_PAIR",
            macDeviceId,
            androidDeviceId,
            androidPublicKey,
            pairingToken,
            challenge
        ].joined(separator: "\n")
    }
}
