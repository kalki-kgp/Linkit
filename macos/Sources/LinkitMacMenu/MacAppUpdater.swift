import AppKit
import CryptoKit
import Darwin
import Foundation
import LinkitMacCore

enum MacAppUpdaterError: LocalizedError {
    case notRunningFromAppBundle
    case missingDownloadedApp
    case bundleIdentifierMismatch(String?)
    case versionMismatch(found: String?, expected: String)
    case buildMismatch(found: String?, expected: Int)
    case checksumMismatch(expected: String, actual: String)
    case installerLaunchFailed

    var errorDescription: String? {
        switch self {
        case .notRunningFromAppBundle:
            return "Run Linkit from the packaged app before updating."
        case .missingDownloadedApp:
            return "The downloaded update did not contain Linkit.app."
        case let .bundleIdentifierMismatch(identifier):
            return "The downloaded app has the wrong bundle identifier: \(identifier ?? "missing")."
        case let .versionMismatch(found, expected):
            return "The downloaded app version is \(found ?? "missing"), expected \(expected)."
        case let .buildMismatch(found, expected):
            return "The downloaded app build is \(found ?? "missing"), expected \(expected)."
        case let .checksumMismatch(expected, actual):
            return "Update checksum mismatch. Expected \(expected), got \(actual)."
        case .installerLaunchFailed:
            return "Could not start the updater helper."
        }
    }
}

final class MacAppUpdater {
    private let checker: LinkitUpdateChecker
    private let bundle: Bundle
    private let fileManager: FileManager

    init(bundle: Bundle = .main, fileManager: FileManager = .default) throws {
        let configuration = try LinkitUpdateConfiguration.fromBundle(bundle)
        self.checker = LinkitUpdateChecker(configuration: configuration)
        self.bundle = bundle
        self.fileManager = fileManager
    }

    var currentVersion: String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var currentBuild: Int {
        let raw = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return Int(raw) ?? 0
    }

    func checkForUpdates() async throws -> LinkitUpdateCheckResult {
        try await checker.check(currentVersion: currentVersion, currentBuild: currentBuild)
    }

    func install(_ update: LinkitAvailableUpdate) async throws {
        guard bundle.bundleURL.pathExtension == "app" else {
            throw MacAppUpdaterError.notRunningFromAppBundle
        }

        let stagingRoot = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: bundle.bundleURL,
            create: true
        )
        let zipURL = stagingRoot.appendingPathComponent("Linkit-\(update.version)-\(update.build).zip")
        let extractURL = stagingRoot.appendingPathComponent("expanded", isDirectory: true)

        try await download(update.manifest.url, to: zipURL)
        try verifyChecksum(zipURL, expected: update.manifest.normalizedChecksum)
        try extractZip(zipURL, to: extractURL)
        let newAppURL = try findAppBundle(in: extractURL)
        try validateDownloadedApp(newAppURL, update: update)
        try launchInstaller(newAppURL: newAppURL, stagingRoot: stagingRoot)
    }

    private func download(_ url: URL, to destination: URL) async throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        if url.isFileURL {
            try fileManager.copyItem(at: url, to: destination)
            return
        }

        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
    }

    private func verifyChecksum(_ fileURL: URL, expected: String) throws {
        let data = try Data(contentsOf: fileURL)
        let actual = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actual == expected else {
            throw MacAppUpdaterError.checksumMismatch(expected: expected, actual: actual)
        }
    }

    private func extractZip(_ zipURL: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try runProcess("/usr/bin/ditto", arguments: ["-x", "-k", zipURL.path, destination.path])
    }

    private func findAppBundle(in folder: URL) throws -> URL {
        let expected = folder.appendingPathComponent("Linkit.app", isDirectory: true)
        if fileManager.fileExists(atPath: expected.path) {
            return expected
        }

        let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "app" && url.lastPathComponent == "Linkit.app" {
                return url
            }
        }
        throw MacAppUpdaterError.missingDownloadedApp
    }

    private func validateDownloadedApp(_ appURL: URL, update: LinkitAvailableUpdate) throws {
        guard let downloaded = Bundle(url: appURL) else {
            throw MacAppUpdaterError.missingDownloadedApp
        }
        guard downloaded.bundleIdentifier == bundle.bundleIdentifier else {
            throw MacAppUpdaterError.bundleIdentifierMismatch(downloaded.bundleIdentifier)
        }

        let version = downloaded.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard version == update.version else {
            throw MacAppUpdaterError.versionMismatch(found: version, expected: update.version)
        }

        let build = downloaded.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard Int(build ?? "") == update.build else {
            throw MacAppUpdaterError.buildMismatch(found: build, expected: update.build)
        }
    }

    private func launchInstaller(newAppURL: URL, stagingRoot: URL) throws {
        let scriptURL = stagingRoot.appendingPathComponent("install-linkit-update.zsh")
        let script = installerScript(
            currentAppURL: bundle.bundleURL,
            newAppURL: newAppURL,
            stagingRoot: stagingRoot,
            currentPID: getpid()
        )
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        try process.run()
        guard process.isRunning else {
            throw MacAppUpdaterError.installerLaunchFailed
        }
    }

    private func installerScript(currentAppURL: URL, newAppURL: URL, stagingRoot: URL, currentPID: pid_t) -> String {
        let currentApp = shellQuote(currentAppURL.path)
        let newApp = shellQuote(newAppURL.path)
        let staging = shellQuote(stagingRoot.path)
        return """
        #!/bin/zsh
        set -euo pipefail

        APP_PATH=\(currentApp)
        NEW_APP=\(newApp)
        STAGING_ROOT=\(staging)
        BACKUP="${APP_PATH}.previous-update"
        PID=\(currentPID)

        install_ops() {
          /bin/rm -rf "$BACKUP"
          if [[ -d "$APP_PATH" ]]; then
            /bin/mv "$APP_PATH" "$BACKUP"
          fi
          /usr/bin/ditto "$NEW_APP" "$APP_PATH"
          /bin/rm -rf "$BACKUP"
        }

        restore_backup() {
          if [[ -d "$BACKUP" && ! -d "$APP_PATH" ]]; then
            /bin/mv "$BACKUP" "$APP_PATH"
          fi
        }

        if [[ "${1:-}" == "--apply-only" ]]; then
          install_ops
          exit 0
        fi

        while /bin/kill -0 "$PID" 2>/dev/null; do
          /bin/sleep 0.2
        done

        if ! install_ops; then
          restore_backup
          PRIVILEGED_COMMAND=\(shellQuote(shellQuote(stagingRoot.appendingPathComponent("install-linkit-update.zsh").path) + " --apply-only"))
          /usr/bin/osascript -e "do shell script \\"$PRIVILEGED_COMMAND\\" with administrator privileges"
        fi

        /usr/bin/open "$APP_PATH"
        /bin/rm -rf "$STAGING_ROOT"
        """
    }

    private func runProcess(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw URLError(.cannotOpenFile)
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
