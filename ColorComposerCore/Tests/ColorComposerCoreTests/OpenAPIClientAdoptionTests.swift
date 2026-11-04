import Foundation
import XCTest

final class OpenAPIClientAdoptionTests: XCTestCase {
    func testPackageDeclaresGeneratedClientRuntimeAndBuildPlugin() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let packageURL = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: packageURL, encoding: .utf8)

        XCTAssertTrue(manifest.contains("swift-openapi-generator"))
        XCTAssertTrue(manifest.contains("swift-openapi-runtime"))
        XCTAssertTrue(manifest.contains("OpenAPIGenerator"))
        XCTAssertTrue(manifest.contains("OpenAPIURLSession"))
    }
}
