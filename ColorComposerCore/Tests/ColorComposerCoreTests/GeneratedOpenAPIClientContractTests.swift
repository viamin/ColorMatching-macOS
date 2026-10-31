import Foundation
import XCTest

/// Guards the package-level part of the API-contract migration. Runtime API
/// behavior remains covered by `PaletteAPIClientTests`; this test ensures it
/// is backed by the generated OpenAPI client rather than handwritten wire DTOs.
final class GeneratedOpenAPIClientContractTests: XCTestCase {
    func testCorePackageDeclaresOpenAPIGeneratorAndRuntimeDependencies() throws {
        let manifest = try String(contentsOf: packageManifestURL())

        XCTAssertTrue(manifest.contains("swift-openapi-generator"))
        XCTAssertTrue(manifest.contains("swift-openapi-runtime"))
        XCTAssertTrue(manifest.contains("OpenAPIGenerator"))
        XCTAssertTrue(manifest.contains("OpenAPIRuntime"))
    }

    private func packageManifestURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
    }
}
