import Foundation
import XCTest

final class OpenAPIClientManifestTests: XCTestCase {
    func testPackageDeclaresOpenAPIGeneratorAndRuntimeDependencies() throws {
        let packageManifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let contents = try String(contentsOf: packageManifest)

        XCTAssertTrue(contents.contains("swift-openapi-generator"))
        XCTAssertTrue(contents.contains("swift-openapi-runtime"))
    }
}
