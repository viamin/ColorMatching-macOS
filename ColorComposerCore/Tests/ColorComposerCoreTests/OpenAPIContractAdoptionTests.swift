import Foundation
import XCTest

/// Red-phase structural tests for the generated OpenAPI client migration
/// (issue #39, depends on viamin/color_matching#110).
///
/// These assert the *adoption deliverables*, complementing the behavior
/// tests in `PaletteAPIClientTests` (which pin request/response semantics
/// the migration must preserve):
///
/// 1. `Package.swift` declares `swift-openapi-generator` (plugin) and
///    `swift-openapi-runtime` (library).
/// 2. An OpenAPI document is committed at the package root.
/// 3. The document covers the contract `PaletteAPIClient` consumes:
///    `GET /api/v1/printer_profiles`, `GET /api/v1/colors`, and the
///    `bearerAuth` security scheme — served live by
///    `GET /api/v1/openapi.json` (see `docs/parity-corpus.md`).
/// 4. Generated client sources exist under the package sources.
///
/// They fail until the migration lands; they are the acceptance tests for
/// the implementation run that follows this test-writing run.
final class OpenAPIContractAdoptionTests: XCTestCase {
    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ColorComposerCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ColorComposerCore (package root)
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testPackageDeclaresOpenAPIGeneratorAndRuntimeDependencies() throws {
        let manifest = try read("Package.swift")

        XCTAssertTrue(manifest.contains("swift-openapi-generator"), "Package.swift must depend on swift-openapi-generator")
        XCTAssertTrue(manifest.contains("swift-openapi-runtime"), "Package.swift must depend on swift-openapi-runtime")
        XCTAssertTrue(manifest.contains("OpenAPIGenerator"), "the ColorComposerCore target must apply the OpenAPIGenerator plugin")
    }

    func testOpenAPIDocumentIsCommittedAtPackageRoot() throws {
        let document = try XCTUnwrap(openAPIDocument(), "commit the OpenAPI document as ColorComposerCore/openapi.yaml (or openapi.json), refreshed from GET /api/v1/openapi.json")

        XCTAssertFalse(document.text.isEmpty, "the OpenAPI document must not be empty")
        XCTAssertTrue(document.text.contains("printer_profiles"), "document must describe the printer_profiles endpoint")
        XCTAssertTrue(document.text.contains("/colors"), "document must describe the colors endpoint")
        XCTAssertTrue(document.text.contains("bearerAuth"), "document must declare the bearerAuth security scheme used by PaletteAPIClient")
    }

    /// Structural contract checks when the committed document is JSON
    /// (the exact rendering the server serves). YAML documents are covered
    /// by the marker checks above.
    func testJSONOpenAPIDocumentCoversContractUsedByPaletteAPIClient() throws {
        guard let document = openAPIDocument(), document.url.pathExtension == "json" else {
            throw XCTSkip("Only applies to openapi.json; a YAML document is validated by the marker test")
        }
        let spec = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(document.text.utf8)) as? [String: Any], "openapi.json must decode as a JSON object")

        let paths = try XCTUnwrap(spec["paths"] as? [String: Any])
        XCTAssertNotNil((paths["/api/v1/printer_profiles"] as? [String: Any])?["get"], "GET /api/v1/printer_profiles must be documented")
        XCTAssertNotNil((paths["/api/v1/colors"] as? [String: Any])?["get"], "GET /api/v1/colors must be documented")

        let components = try XCTUnwrap(spec["components"] as? [String: Any])
        let schemes = try XCTUnwrap(components["securitySchemes"] as? [String: Any])
        let bearer = try XCTUnwrap(schemes["bearerAuth"] as? [String: Any])
        XCTAssertEqual(bearer["type"] as? String, "http")
        XCTAssertEqual(bearer["scheme"] as? String, "bearer")

        let schemas = try XCTUnwrap(components["schemas"] as? [String: Any])
        let profilesResponse = try XCTUnwrap(schemas["PrinterProfilesResponse"] as? [String: Any])
        XCTAssertTrue((profilesResponse["required"] as? [String])?.contains("printer_profiles") == true)

        let colorsResponse = try XCTUnwrap(schemas["ColorsResponse"] as? [String: Any])
        for requiredField in ["printer_profile", "colors"] {
            XCTAssertTrue((colorsResponse["required"] as? [String])?.contains(requiredField) == true, "ColorsResponse must require \(requiredField)")
        }
    }

    func testGeneratedClientSourcesExistInPackage() throws {
        let sourcesRoot = packageRoot().appendingPathComponent("Sources/ColorComposerCore")
        let enumerator = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)
        let swiftFiles = enumerator?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []

        let importsRuntime = swiftFiles.filter { url in
            (try? String(contentsOf: url, encoding: .utf8))?.contains("import OpenAPIRuntime") == true
        }
        XCTAssertTrue(!importsRuntime.isEmpty, "generated client (or PaletteAPIClient wrapping it) must live under Sources and import OpenAPIRuntime")
    }

    // MARK: - Internals

    private func openAPIDocument() -> (url: URL, text: String)? {
        for name in ["openapi.yaml", "openapi.json", "openapi.yml"] {
            let url = packageRoot().appendingPathComponent(name)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return (url, text)
            }
        }
        return nil
    }
}
