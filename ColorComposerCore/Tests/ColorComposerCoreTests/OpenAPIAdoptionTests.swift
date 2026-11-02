import Foundation
import XCTest

/// Structural adoption tests for the generated OpenAPI client (issue #39).
///
/// These deliberately fail until the package consumes the `color_matching`
/// OpenAPI spec (viamin/color_matching#110):
///  * `Package.swift` declares the `swift-openapi-generator` plugin and the
///    `swift-openapi-runtime` dependency, and
///  * the server's OpenAPI document is committed at
///    `ColorComposerCore/OpenAPI/openapi.json` for code generation.
///
/// Behavioral wire-contract coverage lives in `PaletteAPIClientTests`: the
/// migration to the generated client must keep those tests (and the disk
/// cache / offline fallback coverage in `ProfileColorCacheTests`) green.
final class OpenAPIAdoptionTests: XCTestCase {
    /// `.../ColorComposerCore/Tests/ColorComposerCoreTests/OpenAPIAdoptionTests.swift`
    /// → package root `.../ColorComposerCore`.
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testPackageDeclaresOpenAPIRuntimeDependency() throws {
        let manifest = try String(contentsOf: packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must declare the swift-openapi-runtime dependency so the generated client links (issue #39)"
        )
    }

    func testPackageDeclaresOpenAPIGenerator() throws {
        let manifest = try String(contentsOf: packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must wire the swift-openapi-generator plugin that produces the typed client from the OpenAPI document (issue #39)"
        )
    }

    func testOpenAPIDocumentIsCommittedForCodeGeneration() throws {
        let documentURL = packageRoot.appendingPathComponent("OpenAPI/openapi.json")
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            XCTFail("OpenAPI document is missing at \(documentURL.path). Export it from a running color_matching server (GET /api/v1/openapi.json) and commit it (issue #39)")
            return
        }

        let document = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: documentURL)) as? [String: Any],
            "OpenAPI document must be a JSON object"
        )
        let version = try XCTUnwrap(document["openapi"] as? String, "OpenAPI document must declare its version")
        XCTAssertTrue(version.hasPrefix("3."), "expected an OpenAPI 3.x document, found \(version)")

        let paths = try XCTUnwrap(document["paths"] as? [String: Any], "OpenAPI document must declare paths")
        XCTAssertTrue(paths.keys.contains("/api/v1/printer_profiles"), "OpenAPI document must cover GET /api/v1/printer_profiles")
        XCTAssertTrue(paths.keys.contains("/api/v1/colors"), "OpenAPI document must cover GET /api/v1/colors")
    }
}
