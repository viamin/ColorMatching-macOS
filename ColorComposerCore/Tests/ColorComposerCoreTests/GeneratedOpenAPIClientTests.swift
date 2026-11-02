import Foundation
import XCTest

/// Guards the generated-client adoption (issue #39): the OpenAPI document
/// published by viamin/color_matching#110 must be committed under the package
/// sources, and the package must generate the typed client at build time via
/// `swift-openapi-generator` and link `swift-openapi-runtime`.
///
/// These checks are deliberately structural so they hold whether
/// `PaletteAPIClient` migrates onto the generated `Client` directly or wraps
/// it; the behavioral half of the contract (query parameter, envelopes,
/// bearer auth, error mapping) is pinned by `PaletteAPIClientTests` and
/// `APIDecodingTests`, which must stay green through the migration.
final class GeneratedOpenAPIClientTests: XCTestCase {
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ColorComposerCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ColorComposerCore
    }

    func testPackageAdoptsOpenAPIGeneratorAndRuntime() throws {
        let manifest = try String(
            contentsOf: Self.packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must adopt swift-openapi-generator so the typed client is generated at build time (issue #39)."
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must link swift-openapi-runtime for the generated client (issue #39)."
        )
        XCTAssertTrue(
            manifest.contains("OpenAPIGenerator"),
            "The ColorComposerCore target must apply the OpenAPIGenerator build plugin (issue #39)."
        )
    }

    func testOpenAPIDocumentIsCommittedAndDescribesTheV1PaletteAPI() throws {
        let document = try XCTUnwrap(
            Self.openAPIDocument(),
            "No OpenAPI document (openapi.yaml/openapi.yml/openapi.json) is committed under "
                + "Sources/ColorComposerCore. Commit the spec published by viamin/color_matching#110 — "
                + "see docs/generated-api-client.md."
        )
        let text = try String(contentsOf: document, encoding: .utf8)

        XCTAssertTrue(
            text.contains("/api/v1/printer_profiles"),
            "The committed OpenAPI document must describe GET /api/v1/printer_profiles, the endpoint PaletteAPIClient consumes."
        )
        XCTAssertTrue(
            text.contains("/api/v1/colors"),
            "The committed OpenAPI document must describe GET /api/v1/colors, the endpoint PaletteAPIClient consumes."
        )
        XCTAssertTrue(
            text.contains("openapi: 3") || text.contains("\"openapi\": \"3") || text.contains("\"openapi\":\"3"),
            "The committed OpenAPI document must declare OpenAPI 3.x."
        )
    }

    private static func openAPIDocument() -> URL? {
        let sources = packageRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("ColorComposerCore", isDirectory: true)
        let documentNames: Set<String> = ["openapi.yaml", "openapi.yml", "openapi.json"]
        return FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .first { documentNames.contains($0.lastPathComponent) }
    }
}
