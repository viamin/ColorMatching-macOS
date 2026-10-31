import Foundation
import XCTest

/// Contract tests for the OpenAPI adoption (issue #39): `ColorComposerCore`
/// must vendor the `color_matching` OpenAPI document
/// (`Sources/ColorComposerCore/OpenAPI/openapi.yaml`, refreshable from
/// `GET /api/v1/openapi.json`), declare the `swift-openapi-generator` plugin
/// and `swift-openapi-runtime` dependency, and the vendored document must
/// cover the endpoints `PaletteAPIClient` consumes. Structural by design —
/// these pin the tooling contract without depending on generated symbols.
final class OpenAPIContractTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ColorComposerCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ColorComposerCore (package root)
    }

    func testPackageDeclaresOpenAPIGeneratorAndRuntime() throws {
        let manifest = try String(contentsOf: packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8)

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must declare the swift-openapi-generator plugin so the typed client is generated at build time"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must declare the swift-openapi-runtime dependency the generated client runs on"
        )
    }

    func testVendoredOpenAPIDocumentIsCommitted() throws {
        XCTAssertNotNil(
            vendoredDocumentURL(),
            "No OpenAPI document at Sources/ColorComposerCore/OpenAPI/openapi.yaml (or .json). \
            Fetch it from a running color_matching server: GET /api/v1/openapi.json \
            (see docs/parity-corpus.md for the refresh recipe)."
        )
    }

    func testVendoredDocumentCoversEndpointsTheClientConsumes() throws {
        let documentURL = try XCTUnwrap(vendoredDocumentURL(), "vendored OpenAPI document missing")
        let document = try String(contentsOf: documentURL, encoding: .utf8)

        XCTAssertTrue(document.contains("/api/v1/printer_profiles"), "vendored spec must document GET /api/v1/printer_profiles")
        XCTAssertTrue(document.contains("/api/v1/colors"), "vendored spec must document GET /api/v1/colors")
        XCTAssertTrue(document.contains("bearerAuth"), "vendored spec must document the bearer auth PaletteAPIClient sends")
    }

    private func vendoredDocumentURL() -> URL? {
        let directory = packageRoot
            .appendingPathComponent("Sources/ColorComposerCore/OpenAPI", isDirectory: true)
        return ["openapi.yaml", "openapi.yml", "openapi.json"]
            .map { directory.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
