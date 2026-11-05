import Foundation
import XCTest

final class OpenAPIClientPackageTests: XCTestCase {
    func testPackageDeclaresGeneratedClientRuntimeAndPlugin() throws {
        let packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try String(contentsOf: packageDirectory.appendingPathComponent("Package.swift"))

        XCTAssertTrue(manifest.contains("swift-openapi-generator"))
        XCTAssertTrue(manifest.contains("swift-openapi-runtime"))
        XCTAssertTrue(manifest.contains("OpenAPIGenerator"))
        XCTAssertTrue(manifest.contains("OpenAPIRuntime"))
    }
}
