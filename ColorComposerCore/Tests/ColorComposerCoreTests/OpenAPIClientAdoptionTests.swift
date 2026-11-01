import Foundation
import XCTest

/// Contract tests for the generated OpenAPI client adoption (issue #39).
///
/// The app must consume the published `color_matching` OpenAPI document
/// (viamin/color_matching#110) through `swift-openapi-generator` /
/// `swift-openapi-runtime` inside `ColorComposerCore`, while
/// `PaletteAPIClient` keeps its public behavior (see
/// `PaletteAPIClientMigrationTests` for the pinned wire contract, and
/// `docs/openapi-client-adoption.md` for the migration plan these tests
/// enforce).
///
/// These tests are deliberately red until the migration lands: they name the
/// two artifacts the adoption must add — the manifest dependencies and the
/// committed document — and pin the `/api/v1` request shapes the generated
/// client has to reproduce.
final class OpenAPIClientAdoptionTests: XCTestCase {
    private enum AdoptionError: Error {
        case documentMissing
    }

    /// ColorComposerCore/ from this test file's path.
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var manifestURL: URL { packageRoot.appendingPathComponent("Package.swift") }
    private var documentURL: URL { packageRoot.appendingPathComponent("OpenAPI/color_matching.json") }

    // MARK: - Manifest

    func testPackageManifestDeclaresOpenAPIGeneratorAndRuntime() throws {
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "ColorComposerCore/Package.swift must declare swift-openapi-generator (the code-generation plugin) — issue #39, viamin/color_matching#110"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "ColorComposerCore/Package.swift must declare swift-openapi-runtime (the generated client's runtime) — issue #39, viamin/color_matching#110"
        )
    }

    // MARK: - Document

    func testOpenAPIDocumentIsCommitted() throws {
        let committed = FileManager.default.fileExists(atPath: documentURL.path)
        XCTAssertTrue(
            committed,
            "The color_matching OpenAPI document must be committed at ColorComposerCore/OpenAPI/color_matching.json (viamin/color_matching#110) so the client can be generated reproducibly — issue #39"
        )
        if !committed { throw AdoptionError.documentMissing }
    }

    private func loadDocument(file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            XCTFail("OpenAPI document missing at ColorComposerCore/OpenAPI/color_matching.json — see testOpenAPIDocumentIsCommitted", file: file, line: line)
            throw AdoptionError.documentMissing
        }
        let data = try Data(contentsOf: documentURL)
        let document = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "The OpenAPI document must be a JSON object",
            file: file, line: line
        )
        return document
    }

    func testOpenAPIDocumentDeclaresA3xVersion() throws {
        let document = try loadDocument()
        let version = try XCTUnwrap(document["openapi"] as? String, "The document must carry an `openapi` version string")
        XCTAssertTrue(version.hasPrefix("3."), "Expected an OpenAPI 3.x document, found \(version)")
    }

    func testOpenAPIDocumentDescribesBothApiV1PaletteEndpoints() throws {
        let document = try loadDocument()
        let paths = try XCTUnwrap(document["paths"] as? [String: Any], "The document must define `paths`")

        let printerProfiles = try XCTUnwrap(
            paths["/api/v1/printer_profiles"] as? [String: Any],
            "The document must describe GET /api/v1/printer_profiles — the endpoint PaletteAPIClient.fetchPrinterProfiles() consumes"
        )
        XCTAssertNotNil(printerProfiles["get"], "/api/v1/printer_profiles must be a GET operation")

        let colors = try XCTUnwrap(
            paths["/api/v1/colors"] as? [String: Any],
            "The document must describe GET /api/v1/colors — the endpoint PaletteAPIClient.fetchColors(printerProfileID:) consumes"
        )
        XCTAssertNotNil(colors["get"], "/api/v1/colors must be a GET operation")
    }

    func testOpenAPIDocumentRequiresPrinterProfileIDQueryParameter() throws {
        let document = try loadDocument()
        let paths = try XCTUnwrap(document["paths"] as? [String: Any], "The document must define `paths`")
        let colors = try XCTUnwrap(paths["/api/v1/colors"] as? [String: Any])
        let get = try XCTUnwrap(colors["get"] as? [String: Any], "/api/v1/colors must be a GET operation")

        var parameters: [[String: Any]] = (get["parameters"] as? [[String: Any]]) ?? []
        parameters += (colors["parameters"] as? [[String: Any]]) ?? []
        XCTAssertTrue(
            parameters.contains { ($0["name"] as? String) == "printer_profile_id" },
            "GET /api/v1/colors must declare the printer_profile_id query parameter the client sends today"
        )
    }

    /// The generated client must decode the same snake_case wire envelopes the
    /// hand-written DTOs decode (`printer_profiles`, `colors`,
    /// `printer_profile`, `responses`) — this is the "/api/v1 shape changes"
    /// audit from the issue: if the published spec renamed any of them, this
    /// pin — and the decoding tests — catch it.
    func testOpenAPIDocumentUsesTheSnakeCaseEnvelopePropertyNames() throws {
        let raw = try String(contentsOf: documentURL, encoding: .utf8)
        for property in ["printer_profiles", "printer_profile_id", "printer_profile", "responses"] {
            XCTAssertTrue(
                raw.contains("\"\(property)\""),
                "The OpenAPI document must use the snake_case property `\(property)` the client decodes today — a rename is an API shape change to record in the PR"
            )
        }
    }
}
