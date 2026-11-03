import Foundation
import XCTest

final class OpenAPIClientAdoptionTests: XCTestCase {
    func testPackageDeclaresGeneratorAndRuntimeDependencies() throws {
        let packageURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: packageURL)

        XCTAssertTrue(manifest.contains("swift-openapi-generator"))
        XCTAssertTrue(manifest.contains("swift-openapi-runtime"))
    }
}
