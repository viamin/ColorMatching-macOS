import Foundation
import XCTest

/// Structural preconditions for the generated-OpenAPI-client migration
/// (issue #39): the package must depend on `swift-openapi-generator` +
/// `swift-openapi-runtime` and commit the server's OpenAPI document where
/// the generator looks for it. These fail until the migration lands; see
/// `docs/openapi-generated-client.md` for the expected layout.
final class OpenAPIClientMigrationTests: XCTestCase {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .resolvingSymlinksInPath()
        .deletingLastPathComponent() // ColorComposerCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // ColorComposerCore

    func testPackageManifestDeclaresOpenAPIGeneratorAndRuntime() throws {
        let manifest = try String(
            contentsOf: Self.packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must add the swift-openapi-generator plugin package (issue #39)"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must add the swift-openapi-runtime dependency (issue #39)"
        )
    }

    func testOpenAPIDocumentIsCommittedForGeneration() throws {
        let document = try XCTUnwrap(
            Self.committedOpenAPIDocument(),
            """
            No OpenAPI document found at \
            \(Self.packageRoot.path)/Sources/ColorComposerCore/OpenAPI/openapi.{yaml,yml,json}. \
            Commit the spec published by viamin/color_matching (PR #110) there so \
            swift-openapi-generator can produce the typed client.
            """
        )
        let contents = try String(contentsOf: document, encoding: .utf8)

        XCTAssertTrue(contents.contains("openapi: 3") || contents.contains(#""openapi": "3"#), "Not an OpenAPI v3 document")
        XCTAssertTrue(contents.contains("/api/v1/printer_profiles"), "Spec must declare GET /api/v1/printer_profiles")
        XCTAssertTrue(contents.contains("/api/v1/colors"), "Spec must declare GET /api/v1/colors")
        XCTAssertTrue(
            contents.contains("printer_profile_id"),
            "Spec must declare the printer_profile_id query parameter for /api/v1/colors"
        )
    }

    /// The generated client decodes into the same wire shapes `PaletteAPIClient`
    /// serves today; the spec's response schemas must therefore keep the
    /// snake_case envelope keys the DTOs decode from.
    func testOpenAPIDocumentKeepsTheEnvelopeShapesTheClientDecodes() throws {
        guard let document = Self.committedOpenAPIDocument() else {
            throw XCTSkip("OpenAPI document not committed yet (see testOpenAPIDocumentIsCommittedForGeneration)")
        }
        let contents = try String(contentsOf: document, encoding: .utf8)

        XCTAssertTrue(contents.contains("printer_profiles"), "Spec must keep the printer_profiles envelope key")
        XCTAssertTrue(contents.contains("printer_profile"), "Spec must keep the printer_profile envelope key")
    }

    private static func committedOpenAPIDocument() -> URL? {
        let directory = packageRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("ColorComposerCore", isDirectory: true)
            .appendingPathComponent("OpenAPI", isDirectory: true)
        for name in ["openapi.yaml", "openapi.yml", "openapi.json"] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
