import Foundation
import XCTest
@testable import V07Core

final class V07BuildTests: XCTestCase {
    func testReleasePreservesInstalledIdentityAndSeparatesDevelopmentState() {
        let release = V07Build.release
        let development = V07Build.development
        XCTAssertEqual(release.bundleIdentifier, "dev.davis.v07")
        XCTAssertEqual(release.displayName, "V07")
        XCTAssertEqual(development.displayName, "V07 Dev")
        XCTAssertNotEqual(release.bundleIdentifier, development.bundleIdentifier)
        XCTAssertNotEqual(release.dataDirectory, development.dataDirectory)
        XCTAssertNotEqual(release.credentialService, development.credentialService)
        XCTAssertNotEqual(release.windowAutosaveName, development.windowAutosaveName)
        XCTAssertEqual(development.credentialService, "dev.davis.v07.dev.server")
        XCTAssertFalse(release.isDevelopment)
        XCTAssertTrue(development.isDevelopment)
    }
}
