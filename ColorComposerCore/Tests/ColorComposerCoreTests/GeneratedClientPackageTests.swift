import Foundation
import XCTest

final class GeneratedClientPackageTests: XCTestCase {
    func testPackageDeclaresSwiftOpenAPIRuntimeAndGenerator() throws {
        let packageManifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let contents = try String(contentsOf: packageManifest)

        XCTAssertTrue(contents.contains("swift-openapi-runtime"))
        XCTAssertTrue(contents.contains("swift-openapi-generator"))
    }
}
