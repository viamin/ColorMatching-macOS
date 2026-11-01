import Foundation
import XCTest

/// Red-phase contract for the generated OpenAPI client adoption (issue #39).
///
/// These tests pin the two committable artifacts of the migration so the
/// implementation run (a) wires `swift-openapi-generator` + `swift-openapi-runtime`
/// into the `ColorComposerCore` package and (b) vendors the server's OpenAPI
/// document at the conventional swift-openapi-generator location, where it
/// covers exactly the `/api/v1` surface `PaletteAPIClient` consumes today.
///
/// The *behavioral* half of the migration gate — URLs, headers, envelope
/// decoding, `PaletteAPIError` mapping — lives in
/// `PaletteAPIClientContractTests`; the disk-cache/offline-stale behavior it
/// feeds (ColorCatalog + ProfileColorCache) is covered by
/// `ProfileColorCacheTests`.
///
/// These tests are expected to fail until the implementation lands.
final class OpenAPIClientAdoptionTests: XCTestCase {
    /// `…/ColorComposerCore/Tests/ColorComposerCoreTests/<this file>` → package root.
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Package manifest wiring

    func testPackageManifestWiresOpenAPIGeneratorPluginAndRuntime() throws {
        let manifest = try read("Package.swift")

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must declare the apple/swift-openapi-generator package (provides the OpenAPIGenerator build plugin)"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must declare a dependency on apple/swift-openapi-runtime (the generated client's runtime types)"
        )
        XCTAssertTrue(
            manifest.contains("OpenAPIGenerator"),
            "The ColorComposerCore target must apply the OpenAPIGenerator plugin to generate the typed client at build time"
        )
    }

    // MARK: - Vendored OpenAPI document

    private func openAPIDocumentURL() -> URL {
        packageRoot.appendingPathComponent("Sources/ColorComposerCore/OpenAPI/openapi.json")
    }

    func testOpenAPIDocumentIsCommittedAndCoversConsumedEndpoints() throws {
        let documentURL = openAPIDocumentURL()
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            XCTFail("""
            Missing \(documentURL.path). Vendor the server's OpenAPI document — the byte-for-byte \
            body of GET /api/v1/openapi.json from color_matching (viamin/color_matching#113) — at \
            Sources/ColorComposerCore/OpenAPI/openapi.json (see docs/solver-parity-corpus.md).
            """)
            return
        }

        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: documentURL)) as? [String: Any],
            "openapi.json must be a JSON object"
        )

        XCTAssertTrue(
            (document["openapi"] as? String ?? "").hasPrefix("3."),
            "Expected an OpenAPI 3.x document"
        )
        let info = document["info"] as? [String: Any]
        XCTAssertTrue(
            (info?["title"] as? String ?? "").contains("Color Matching"),
            "Expected the color_matching API document info.title"
        )

        let paths = try XCTUnwrap(document["paths"] as? [String: Any], "Document must declare paths")
        for path in ["/api/v1/printer_profiles", "/api/v1/colors"] {
            let item = try XCTUnwrap(paths[path] as? [String: Any], "Document must cover \(path)")
            XCTAssertNotNil(item["get"], "\(path) must expose a GET operation")
        }

        let securitySchemes = try XCTUnwrap(
            (document["components"] as? [String: Any])?["securitySchemes"] as? [String: Any],
            "Document must declare component security schemes"
        )
        XCTAssertNotNil(securitySchemes["bearerAuth"], "Document must declare the bearerAuth scheme used by PaletteAPIClient")
    }

    func testOpenAPIDocumentCoversFieldsTheClientDecodes() throws {
        let documentURL = openAPIDocumentURL()
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            throw XCTSkip("Document not committed yet — covered by testOpenAPIDocumentIsCommittedAndCoversConsumedEndpoints")
        }

        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: documentURL)) as? [String: Any]
        )
        let components = try XCTUnwrap(document["components"] as? [String: Any])
        let schemas = try XCTUnwrap(components["schemas"] as? [String: Any])

        for schema in ["PrinterProfile", "PrinterProfilesResponse", "ColorsResponse"] {
            XCTAssertNotNil(schemas[schema], "Document components must define the \(schema) schema")
        }

        let colors = try XCTUnwrap(schemas["ColorsResponse"] as? [String: Any])
        let properties = try XCTUnwrap(colors["properties"] as? [String: Any])
        for field in ["colors", "printer_profile"] {
            XCTAssertNotNil(properties[field], "ColorsResponse must keep the \(field) field the client decodes")
        }
    }
}
