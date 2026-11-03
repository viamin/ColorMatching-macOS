import Foundation
import XCTest

/// Guards the build-time contract for the API client. The operation-level
/// behavior stays covered by `PaletteAPIClientTests`; this test makes a
/// regression back to handwritten wire decoding visible in review and CI.
final class OpenAPIClientGenerationTests: XCTestCase {
    func testPackageUsesGeneratorAndRuntimeForTheCommittedV1Specification() throws {
        let package = try String(contentsOf: packageRoot.appendingPathComponent("Package.swift"))

        XCTAssertTrue(package.contains("swift-openapi-generator"))
        XCTAssertTrue(package.contains("swift-openapi-runtime"))
        XCTAssertTrue(package.contains("OpenAPIGenerator"))

        let specification = packageRoot
            .appendingPathComponent("Sources/ColorComposerCore/OpenAPI/openapi.yaml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: specification.path))
        guard FileManager.default.fileExists(atPath: specification.path) else { return }

        let document = try String(contentsOf: specification)
        XCTAssertTrue(document.contains("openapi:"))
        XCTAssertTrue(document.contains("/api/v1/printer_profiles"))
        XCTAssertTrue(document.contains("/api/v1/colors"))
        XCTAssertTrue(document.contains("printer_profile_id"))
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
