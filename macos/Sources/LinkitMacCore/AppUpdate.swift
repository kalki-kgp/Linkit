import Foundation

public struct LinkitAppVersion: Comparable, Sendable {
    public let rawValue: String
    private let parts: [Int]

    public init(_ rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.parts = self.rawValue
            .split(separator: ".")
            .map { segment in
                let prefix = segment.prefix { $0.isNumber }
                return Int(prefix) ?? 0
            }
    }

    public static func == (lhs: LinkitAppVersion, rhs: LinkitAppVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right {
                return false
            }
        }
        return true
    }

    public static func < (lhs: LinkitAppVersion, rhs: LinkitAppVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}

public struct LinkitAppUpdateManifest: Decodable, Sendable {
    public let platform: String
    public let version: String
    public let build: Int
    public let url: URL
    public let sha256: String
    public let releaseNotes: String?
    public let minimumSystemVersion: String?

    public var normalizedChecksum: String {
        sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public struct LinkitAvailableUpdate: Sendable {
    public let manifest: LinkitAppUpdateManifest
    public let manifestURL: URL

    public var version: String {
        manifest.version
    }

    public var build: Int {
        manifest.build
    }
}

public enum LinkitUpdateCheckResult: Equatable, Sendable {
    case upToDate
    case available(LinkitAvailableUpdate)

    public static func == (lhs: LinkitUpdateCheckResult, rhs: LinkitUpdateCheckResult) -> Bool {
        switch (lhs, rhs) {
        case (.upToDate, .upToDate):
            return true
        case let (.available(left), .available(right)):
            return left.manifest.version == right.manifest.version
                && left.manifest.build == right.manifest.build
                && left.manifest.url == right.manifest.url
                && left.manifest.normalizedChecksum == right.manifest.normalizedChecksum
        default:
            return false
        }
    }
}

public enum LinkitUpdateError: LocalizedError, Sendable {
    case invalidManifestURL
    case insecureURL(URL)
    case unsupportedPlatform(String)
    case invalidChecksum(String)
    case minimumSystemVersionNotMet(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifestURL:
            return "Linkit update manifest URL is not configured."
        case let .insecureURL(url):
            return "Update URL must use HTTPS: \(url.absoluteString)"
        case let .unsupportedPlatform(platform):
            return "Update is for \(platform), not macOS."
        case let .invalidChecksum(checksum):
            return "Update manifest has an invalid SHA-256 checksum: \(checksum)"
        case let .minimumSystemVersionNotMet(version):
            return "This update requires macOS \(version) or newer."
        }
    }
}

public struct LinkitUpdateConfiguration: Sendable {
    public let manifestURL: URL

    public init(manifestURL: URL) throws {
        try Self.validateDownloadURL(manifestURL)
        self.manifestURL = manifestURL
    }

    public static func fromBundle(_ bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> LinkitUpdateConfiguration {
        let rawURL = environment["LINKIT_UPDATE_MANIFEST_URL"]
            ?? bundle.object(forInfoDictionaryKey: "LinkitUpdateManifestURL") as? String
        guard
            let rawURL,
            !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let url = URL(string: rawURL)
        else {
            throw LinkitUpdateError.invalidManifestURL
        }
        return try LinkitUpdateConfiguration(manifestURL: url)
    }

    public static func validateDownloadURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "file" else {
            throw LinkitUpdateError.insecureURL(url)
        }
    }
}

public final class LinkitUpdateChecker: Sendable {
    private let configuration: LinkitUpdateConfiguration
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(configuration: LinkitUpdateConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
        self.decoder = JSONDecoder()
    }

    public func check(currentVersion: String, currentBuild: Int, platform: String = "macos") async throws -> LinkitUpdateCheckResult {
        let data: Data
        let response: URLResponse
        if configuration.manifestURL.isFileURL {
            data = try Data(contentsOf: configuration.manifestURL)
            response = URLResponse(
                url: configuration.manifestURL,
                mimeType: "application/json",
                expectedContentLength: data.count,
                textEncodingName: "utf-8"
            )
        } else {
            (data, response) = try await session.data(from: configuration.manifestURL)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        let manifest = try decoder.decode(LinkitAppUpdateManifest.self, from: data)
        return try evaluate(
            manifest,
            manifestURL: configuration.manifestURL,
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            platform: platform
        )
    }

    public func evaluate(
        _ manifest: LinkitAppUpdateManifest,
        manifestURL: URL,
        currentVersion: String,
        currentBuild: Int,
        platform: String = "macos"
    ) throws -> LinkitUpdateCheckResult {
        guard manifest.platform.lowercased() == platform.lowercased() else {
            throw LinkitUpdateError.unsupportedPlatform(manifest.platform)
        }
        try LinkitUpdateConfiguration.validateDownloadURL(manifest.url)
        guard manifest.normalizedChecksum.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw LinkitUpdateError.invalidChecksum(manifest.sha256)
        }
        if let minimum = manifest.minimumSystemVersion, !minimum.isEmpty {
            let currentOS = ProcessInfo.processInfo.operatingSystemVersion
            let current = LinkitAppVersion("\(currentOS.majorVersion).\(currentOS.minorVersion).\(currentOS.patchVersion)")
            if current < LinkitAppVersion(minimum) {
                throw LinkitUpdateError.minimumSystemVersionNotMet(minimum)
            }
        }

        let latestVersion = LinkitAppVersion(manifest.version)
        let installedVersion = LinkitAppVersion(currentVersion)
        if latestVersion > installedVersion || (latestVersion == installedVersion && manifest.build > currentBuild) {
            return .available(LinkitAvailableUpdate(manifest: manifest, manifestURL: manifestURL))
        }
        return .upToDate
    }
}
