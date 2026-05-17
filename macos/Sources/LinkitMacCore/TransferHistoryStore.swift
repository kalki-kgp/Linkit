import Foundation

public final class TransferHistoryStore {
    private let lock = NSLock()
    private let fileURL: URL
    private let limit: Int
    private var entries: [TransferHistoryEntry] = []

    public init(baseFolder: URL = LinkitPaths.applicationSupport, limit: Int = 200) throws {
        self.limit = limit
        try FileManager.default.createDirectory(at: baseFolder, withIntermediateDirectories: true)
        self.fileURL = baseFolder.appendingPathComponent("transfer-history.json")
        try load()
    }

    public func append(_ entry: TransferHistoryEntry) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.transferId == entry.transferId }
        entries.insert(entry, at: 0)
        if entries.count > limit {
            entries = Array(entries.prefix(limit))
        }
        do {
            try saveLocked()
        } catch {
            NSLog("Linkit history write failed: \(String(describing: error))")
        }
    }

    public func recent(limit requestedLimit: Int = 10) -> [TransferHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.prefix(requestedLimit))
    }

    private func load() throws {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            entries = []
            return
        }
        let data = try Data(contentsOf: fileURL)
        entries = try JSONDecoder().decode([TransferHistoryEntry].self, from: data)
    }

    private func saveLocked() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
