import Foundation
import XCTest

final class OpenAPIClientManifestContractTests: XCTestCase {
    func testCorePackageDeclaresGeneratedOpenAPIClient() throws {
        let manifest = try String(contentsOf: packageManifestURL(), encoding: .utf8)

        XCTAssertTrue(
            manifest.contains("https://github.com/apple/swift-openapi-runtime"),
            "ColorComposerCore must depend on swift-openapi-runtime."
        )
        XCTAssertTrue(
            manifest.contains("https://github.com/apple/swift-openapi-generator"),
            "ColorComposerCore must depend on swift-openapi-generator."
        )
        XCTAssertTrue(
            manifest.contains(".plugin(name: \"OpenAPIGenerator\", package: \"swift-openapi-generator\")"),
            "The generated OpenAPI target must invoke OpenAPIGenerator."
        )
        XCTAssertTrue(
            manifest.contains(".product(name: \"OpenAPIRuntime\", package: \"swift-openapi-runtime\")"),
            "The generated OpenAPI target must link OpenAPIRuntime."
        )
    }

    private func packageManifestURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
    }
}
