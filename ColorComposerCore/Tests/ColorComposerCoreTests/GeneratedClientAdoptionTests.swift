import Foundation
import XCTest

/// Red-phase contract tests for the generated OpenAPI client adoption
/// (issue #39). `swift test` cannot see not-yet-generated Swift types without
/// breaking compilation of the whole module, so the adoption is pinned by its
/// inspectable artifacts instead:
///
/// 1. an OpenAPI document is committed at the canonical generator input
///    location (`Sources/ColorComposerCore/OpenAPI/openapi.yaml` or
///    `.json` — the layout `swift-openapi-generator` expects);
/// 2. `Package.swift` declares both the `swift-openapi-generator` plugin and
///    the `swift-openapi-runtime` library;
/// 3. a JSON document documents the two `/api/v1` operations
///    `PaletteAPIClient` consumes and the `bearerAuth` security scheme the
///    client already sends.
///
/// These tests fail until the migration lands, then guard its artifacts from
/// regressing. `PaletteAPIClientBehaviorTests` pins the behavioral side
/// (URLs, headers, error mapping, decoding) that the migration must preserve.
final class GeneratedClientAdoptionTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // GeneratedClientAdoptionTests.swift
            .deletingLastPathComponent()  // ColorComposerCoreTests
            .deletingLastPathComponent()  // Tests
    }

    private var canonicalDocumentURLs: [URL] {
        [
            packageRoot
                .appendingPathComponent("Sources/ColorComposerCore/OpenAPI/openapi.json"),
            packageRoot
                .appendingPathComponent("Sources/ColorComposerCore/OpenAPI/openapi.yaml"),
        ]
    }

    private var existingDocumentURL: URL? {
        canonicalDocumentURLs.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func testOpenAPIDocumentIsCommittedAtTheGeneratorInputLocation() throws {
        let document = try XCTUnwrap(
            existingDocumentURL,
            "No OpenAPI document found. Commit the /api/v1 OpenAPI document from "
                + "color_matching (served at GET /api/v1/openapi.json) at one of: "
                + canonicalDocumentURLs.map(\.path).joined(separator: " or ")
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: document.path)
        let size = attributes[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0, "OpenAPI document \(document.path) is empty")
    }

    func testPackageManifestDeclaresOpenAPIGeneratorAndRuntime() throws {
        let manifestURL = packageRoot.appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must declare the swift-openapi-generator plugin dependency"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must declare the swift-openapi-runtime library dependency"
        )
    }

    func testJSONOpenAPIDocumentCoversTheOperationsTheClientUses() throws {
        guard let documentURL = existingDocumentURL, documentURL.pathExtension == "json" else {
            throw XCTSkip("Content assertions run only for the JSON flavor of the OpenAPI document")
        }

        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: documentURL))
        let object = try XCTUnwrap(document as? [String: Any], "OpenAPI document must be a JSON object")
        let paths = try XCTUnwrap(object["paths"] as? [String: Any], "OpenAPI document must declare paths")

        XCTAssertTrue(
            (paths["/api/v1/printer_profiles"] as? [String: Any])?.keys.contains("get") == true,
            "OpenAPI document must document GET /api/v1/printer_profiles"
        )
        XCTAssertTrue(
            (paths["/api/v1/colors"] as? [String: Any])?.keys.contains("get") == true,
            "OpenAPI document must document GET /api/v1/colors"
        )

        let components = try XCTUnwrap(object["components"] as? [String: Any])
        let securitySchemes = try XCTUnwrap(components["securitySchemes"] as? [String: Any])
        XCTAssertNotNil(
            securitySchemes["bearerAuth"],
            "OpenAPI document must declare the bearerAuth security scheme PaletteAPIClient uses"
        )
    }
}
