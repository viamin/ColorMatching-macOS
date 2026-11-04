import Foundation
import XCTest

final class OpenAPIGeneratedClientDependencyTests: XCTestCase {
    func testPackageDeclaresSwiftOpenAPIGeneratorAndRuntime() throws {
        let packageManifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let contents = try String(contentsOf: packageManifest)

        XCTAssertTrue(
            contents.contains("https://github.com/apple/swift-openapi-generator"),
            "ColorComposerCore must generate its API client from the color_matching OpenAPI document."
        )
        XCTAssertTrue(
            contents.contains("https://github.com/apple/swift-openapi-runtime"),
            "ColorComposerCore must use the Swift OpenAPI runtime for generated operations."
        )
    }
}
