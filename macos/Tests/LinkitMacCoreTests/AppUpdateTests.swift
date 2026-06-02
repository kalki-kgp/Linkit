import XCTest
@testable import LinkitMacCore

final class AppUpdateTests: XCTestCase {
    func testVersionComparisonPadsMissingSegments() {
        XCTAssertTrue(LinkitAppVersion("0.3.1") > LinkitAppVersion("0.3"))
        XCTAssertEqual(LinkitAppVersion("1.2.0"), LinkitAppVersion("1.2"))
        XCTAssertTrue(LinkitAppVersion("1.10.0") > LinkitAppVersion("1.9.9"))
    }

    func testEvaluateReturnsAvailableForNewerVersion() throws {
        let checker = try makeChecker()
        let result = try checker.evaluate(
            manifest(version: "0.4.0", build: 4),
            manifestURL: URL(fileURLWithPath: "/tmp/linkit-update.json"),
            currentVersion: "0.3.0",
            currentBuild: 3
        )

        guard case let .available(update) = result else {
            return XCTFail("Expected update to be available.")
        }
        XCTAssertEqual(update.version, "0.4.0")
        XCTAssertEqual(update.build, 4)
    }

    func testEvaluateReturnsAvailableForNewerBuildOnSameVersion() throws {
        let checker = try makeChecker()
        let result = try checker.evaluate(
            manifest(version: "0.3.0", build: 4),
            manifestURL: URL(fileURLWithPath: "/tmp/linkit-update.json"),
            currentVersion: "0.3.0",
            currentBuild: 3
        )

        XCTAssertNotEqual(result, .upToDate)
    }

    func testEvaluateReturnsUpToDateForOlderManifest() throws {
        let checker = try makeChecker()
        let result = try checker.evaluate(
            manifest(version: "0.2.9", build: 9),
            manifestURL: URL(fileURLWithPath: "/tmp/linkit-update.json"),
            currentVersion: "0.3.0",
            currentBuild: 3
        )

        XCTAssertEqual(result, .upToDate)
    }

    func testEvaluateRejectsWrongPlatform() throws {
        let checker = try makeChecker()

        XCTAssertThrowsError(
            try checker.evaluate(
                manifest(platform: "android"),
                manifestURL: URL(fileURLWithPath: "/tmp/linkit-update.json"),
                currentVersion: "0.3.0",
                currentBuild: 3
            )
        )
    }

    func testEvaluateRejectsInvalidChecksum() throws {
        let checker = try makeChecker()

        XCTAssertThrowsError(
            try checker.evaluate(
                manifest(sha256: "nope"),
                manifestURL: URL(fileURLWithPath: "/tmp/linkit-update.json"),
                currentVersion: "0.3.0",
                currentBuild: 3
            )
        )
    }

    private func makeChecker() throws -> LinkitUpdateChecker {
        let configuration = try LinkitUpdateConfiguration(manifestURL: URL(fileURLWithPath: "/tmp/linkit-update.json"))
        return LinkitUpdateChecker(configuration: configuration)
    }

    private func manifest(
        platform: String = "macos",
        version: String = "0.4.0",
        build: Int = 4,
        url: URL = URL(string: "https://example.com/linkit-macos.zip")!,
        sha256: String = String(repeating: "a", count: 64),
        releaseNotes: String? = nil,
        minimumSystemVersion: String? = nil
    ) -> LinkitAppUpdateManifest {
        LinkitAppUpdateManifest(
            platform: platform,
            version: version,
            build: build,
            url: url,
            sha256: sha256,
            releaseNotes: releaseNotes,
            minimumSystemVersion: minimumSystemVersion
        )
    }
}
