import Foundation
import XCTest

final class GeneratedOpenAPIClientAdoptionTests: XCTestCase {
    func testPackageDeclaresTheOpenAPIGeneratorAndRuntimeDependencies() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: package, encoding: .utf8)

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "ColorComposerCore must generate its typed API client from the server OpenAPI document."
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "ColorComposerCore must run the generated typed API client through swift-openapi-runtime."
        )
    }
}
