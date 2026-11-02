import Foundation
import XCTest

final class GeneratedClientPackageTests: XCTestCase {
    func testPackageDeclaresOpenAPIRuntimeAndGeneratorDependencies() throws {
        let packageURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: packageURL)

        XCTAssertTrue(manifest.contains("swift-openapi-runtime"))
        XCTAssertTrue(manifest.contains("swift-openapi-generator"))
        XCTAssertTrue(manifest.contains("OpenAPIRuntime"))
        XCTAssertTrue(manifest.contains("OpenAPIGenerator"))
    }
}
