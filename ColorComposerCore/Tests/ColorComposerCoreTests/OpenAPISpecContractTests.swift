import XCTest

/// Contract checks for the generated OpenAPI client migration (#39).
///
/// `swift-openapi-generator` builds the typed client at build time from an
/// OpenAPI document checked into the package, conventionally at
/// `Sources/ColorComposerCore/OpenAPI/openapi.{yaml,yml,json}`, and the
/// generated code links `swift-openapi-runtime`. These tests fail until the
/// migration lands them and stay green afterwards, so the spec can never
/// silently drop the endpoints `PaletteAPIClient` depends on.
///
/// See `docs/openapi-client-migration.md` for the migration contract.
final class OpenAPISpecContractTests: XCTestCase {
    /// `#filePath` is .../ColorComposerCore/Tests/ColorComposerCoreTests/<file>
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent() // ColorComposerCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ColorComposerCore package root
    }

    private func openAPIDocumentCandidates() -> [URL] {
        let directory = packageRoot
            .appendingPathComponent("Sources/ColorComposerCore/OpenAPI", isDirectory: true)
        return ["openapi.yaml", "openapi.yml", "openapi.json"]
            .map { directory.appendingPathComponent($0, isDirectory: false) }
    }

    private func existingOpenAPIDocument() -> URL? {
        openAPIDocumentCandidates()
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The generated client is derived from a committed OpenAPI document at
    /// the generator's conventional search path. Missing document = no
    /// generated client.
    func testOpenAPIDocumentExistsAtTheGeneratorConventionalPath() {
        let existing = existingOpenAPIDocument()

        XCTAssertNotNil(
            existing,
            "No OpenAPI document found. Expected one of: "
                + openAPIDocumentCandidates().map(\.path).joined(separator: ", ")
                + ". The generated-client migration (#39) must commit the spec "
                + "published by viamin/color_matching#110 at this path."
        )
    }

    /// The document must describe exactly the `/api/v1` surface
    /// `PaletteAPIClient` consumes today: `GET /api/v1/printer_profiles` and
    /// `GET /api/v1/colors?printer_profile_id=N`.
    func testOpenAPIDocumentDescribesTheV1EndpointsPaletteAPIClientUses() throws {
        let documentURL = try XCTUnwrap(existingOpenAPIDocument())
        let text = try String(contentsOf: documentURL, encoding: .utf8)

        if documentURL.pathExtension == "json" {
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                "OpenAPI document is not a JSON object"
            )
            let version = try XCTUnwrap(object["openapi"] as? String, "Missing top-level `openapi` version")
            XCTAssertTrue(version.hasPrefix("3."), "Expected OpenAPI 3.x, found \(version)")

            let paths = try XCTUnwrap(object["paths"] as? [String: Any], "Missing top-level `paths` object")
            XCTAssertNotNil(paths["/api/v1/printer_profiles"], "Spec is missing GET /api/v1/printer_profiles")
            XCTAssertNotNil(paths["/api/v1/colors"], "Spec is missing GET /api/v1/colors")
        } else {
            XCTAssertTrue(text.contains("openapi: 3"), "Expected an `openapi: 3.x` declaration in the YAML document")
            XCTAssertTrue(text.contains("/api/v1/printer_profiles"), "Spec is missing GET /api/v1/printer_profiles")
            XCTAssertTrue(text.contains("/api/v1/colors"), "Spec is missing GET /api/v1/colors")
        }

        // The colors operation is queried by printer profile.
        XCTAssertTrue(
            text.contains("printer_profile_id"),
            "GET /api/v1/colors must expose the printer_profile_id query parameter"
        )
    }

    /// Code generation is wired through the `OpenAPIGenerator` plugin and the
    /// generated code links `swift-openapi-runtime`; both must be declared in
    /// the package manifest.
    func testPackageManifestWiresOpenAPIGeneratorPluginAndRuntime() throws {
        let manifestURL = packageRoot.appendingPathComponent("Package.swift", isDirectory: false)
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must declare the swift-openapi-generator package dependency"
        )
        XCTAssertTrue(
            manifest.contains("OpenAPIGenerator"),
            "Package.swift must invoke the OpenAPIGenerator build plugin on the ColorComposerCore target"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must link swift-openapi-runtime into ColorComposerCore"
        )
    }
}
