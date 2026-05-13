import CryptoKit
import Foundation
import Security

enum LinkitRandom {
    static func token(byteCount: Int = 32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let result = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard result == errSecSuccess else {
            throw NSError(domain: "LinkitRandom", code: Int(result), userInfo: nil)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension Date {
    func iso8601() -> String {
        ISO8601DateFormatter.linkit.string(from: self)
    }
}

extension ISO8601DateFormatter {
    static let linkit: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

extension Sequence where Element == UInt8 {
    func hexString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

extension SHA256.Digest {
    var linkitHex: String {
        Array(self).hexString()
    }
}

public final class LinkitLogger {
    private let lock = NSLock()
    private let handle: FileHandle
    public let fileURL: URL

    public init() throws {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Linkit", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.fileURL = folder.appendingPathComponent("transfer.log")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        self.handle = try FileHandle(forWritingTo: fileURL)
        try self.handle.seekToEnd()
    }

    deinit {
        try? handle.close()
    }

    public func info(_ message: String) {
        write("INFO", message)
    }

    public func error(_ message: String) {
        write("ERROR", message)
    }

    private func write(_ level: String, _ message: String) {
        let line = "\(Date().iso8601()) \(level) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            try handle.write(contentsOf: data)
        } catch {
            fputs("Linkit log write failed: \(error)\n", stderr)
        }
    }
}
