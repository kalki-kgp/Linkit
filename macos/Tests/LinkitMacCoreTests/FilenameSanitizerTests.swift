import XCTest
@testable import LinkitMacCore

final class FilenameSanitizerTests: XCTestCase {
    func testStripsPathTraversalAndLeadingDots() {
        let sanitized = FilenameSanitizer.sanitize("../../.ssh/id_rsa")

        XCTAssertFalse(sanitized.contains(".."))
        XCTAssertFalse(sanitized.hasPrefix("."))
        XCTAssertFalse(sanitized.contains("/"))
        XCTAssertEqual(sanitized, "ssh_id_rsa")
    }

    func testPreservesExtensionWhenCappingLength() {
        let name = String(repeating: "a", count: 240) + ".jpg"

        let sanitized = FilenameSanitizer.sanitize(name, maxLength: 40)

        XCTAssertEqual(sanitized.count, 40)
        XCTAssertTrue(sanitized.hasSuffix(".jpg"))
    }

    func testCollisionCandidatePreservesExtension() {
        XCTAssertEqual(CollisionName.candidate(for: "photo.jpg", attempt: 2), "photo (2).jpg")
        XCTAssertEqual(CollisionName.candidate(for: "README", attempt: 1), "README (1)")
    }
}
