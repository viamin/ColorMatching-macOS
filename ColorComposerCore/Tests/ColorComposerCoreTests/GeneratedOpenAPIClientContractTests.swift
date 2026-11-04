import Foundation
import XCTest
@testable import ColorComposerCore

final class GeneratedOpenAPIClientContractTests: XCTestCase {
    func testPackageDeclaresOpenAPIGeneratorRuntimeAndBuildPlugin() throws {
        let manifest = try String(contentsOf: packageManifestURL(), encoding: .utf8)

        XCTAssertTrue(
            manifest.contains("https://github.com/apple/swift-openapi-generator"),
            "ColorComposerCore must generate its API client from the server OpenAPI document."
        )
        XCTAssertTrue(
            manifest.contains("https://github.com/apple/swift-openapi-runtime"),
            "The generated API client must use swift-openapi-runtime."
        )
        XCTAssertTrue(
            manifest.contains("OpenAPIGenerator"),
            "The ColorComposerCore target must run the OpenAPIGenerator build plugin."
        )
    }

    private func packageManifestURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
    }
}
