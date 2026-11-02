import Foundation
import XCTest

final class OpenAPIClientAdoptionTests: XCTestCase {
    func testPackageDeclaresOpenAPIRuntimeAndGeneratorDependencies() throws {
        let packageURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: packageURL, encoding: .utf8)

        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Issue #39 requires ColorComposerCore to use swift-openapi-runtime."
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Issue #39 requires ColorComposerCore to generate its typed API client."
        )
    }
}
