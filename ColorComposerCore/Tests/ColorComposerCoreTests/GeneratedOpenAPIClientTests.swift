import Foundation
import XCTest

final class GeneratedOpenAPIClientTests: XCTestCase {
    func testPackageDeclaresGeneratedOpenAPIClientToolchain() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: package, encoding: .utf8)

        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "The typed client must use swift-openapi-runtime."
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "The typed client must be generated from the published OpenAPI document."
        )
        XCTAssertTrue(
            manifest.contains("OpenAPIGenerator"),
            "ColorComposerCore must invoke the OpenAPI generator plugin."
        )
    }
}
