import Foundation
import XCTest
@testable import ColorComposerCore

/// Guards the OpenAPI document that feeds the generated client
/// (viamin/color_matching#110 → swift-openapi-generator, issue #39).
///
/// `PaletteAPIClient` (or its generated-client wrapper) must be generated
/// from a document **committed to this repository**, so the typed client and
/// the wire-contract tests in `PaletteAPIClientContractTests` trace back to a
/// reviewable artifact rather than a transient server export.
///
/// Until issue #39's implementation lands, these tests fail: that is the
/// red phase demonstrating the missing document. The accepted commit
/// conventions are (first match wins):
///
/// - `openapi/color-matching.json` / `openapi/color-matching.yaml` (repo root)
/// - `ColorComposerCore/openapi/color-matching.json` / `.yaml`
/// - `ColorComposerCore/Sources/ColorComposerCore/Resources/openapi.yaml`
///
/// Refresh the document from a running server's `/api/openapi.json` (served by
/// `ColorMatchingWeb.ApiSpec` via OpenApiSpex) — see `docs/parity-corpus.md`.
final class OpenAPIDocumentTests: XCTestCase {
    /// Repo root, derived from this file's checked-out location.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // ColorComposerCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // ColorComposerCore
        .deletingLastPathComponent() // repository root

    private static let candidateRelativePaths = [
        "openapi/color-matching.json",
        "openapi/color-matching.yaml",
        "openapi/color-matching.yml",
        "ColorComposerCore/openapi/color-matching.json",
        "ColorComposerCore/openapi/color-matching.yaml",
        "ColorComposerCore/Sources/ColorComposerCore/Resources/openapi.yaml"
    ]

    private static var committedDocumentURL: URL? {
        candidateRelativePaths
            .map { repositoryRoot.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func testOpenAPIDocumentIsCommittedAtAnAcceptedLocation() {
        guard let url = Self.committedDocumentURL else {
            XCTFail(
                "no committed OpenAPI document found (searched: \(Self.candidateRelativePaths.joined(separator: ", "))). "
                    + "Export it from color_matching's /api/openapi.json (viamin/color_matching#110) "
                    + "and commit it so the generated client builds from a reviewable spec."
            )
            return
        }
        XCTAssertGreaterThan(url.pathExtension.count, 0)
    }

    /// The document must describe the two `/api/v1` endpoints
    /// `PaletteAPIClient` consumes, and the bearer scheme the client's
    /// `Authorization` header implements.
    func testOpenAPIDocumentDescribesPaletteEndpointsAndBearerAuth() throws {
        let url = try XCTUnwrap(
            Self.committedDocumentURL,
            "cannot verify endpoint coverage: no OpenAPI document is committed yet (red phase of issue #39)"
        )
        let data = try Data(contentsOf: url)
        XCTAssertFalse(data.isEmpty)

        if url.pathExtension == "json" {
            try assertJSONDocument(data)
        } else {
            try assertYAMLDocument(data)
        }
    }

    // MARK: - Format-specific checks

    /// Structural checks on a JSON OpenAPI document: both paths present with
    /// responses, and a `bearerAuth` http/bearer security scheme.
    private func assertJSONDocument(_ data: Data) throws {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "OpenAPI document is not a JSON object"
        )
        let paths = try XCTUnwrap(object["paths"] as? [String: Any], "document has no paths object")
        let printerProfiles = try XCTUnwrap(paths["/api/v1/printer_profiles"] as? [String: Any])
        let colors = try XCTUnwrap(paths["/api/v1/colors"] as? [String: Any])
        XCTAssertNotNil(printerProfiles["get"], "printer_profiles path must declare GET")
        XCTAssertNotNil(colors["get"], "colors path must declare GET")

        let components = try XCTUnwrap(object["components"] as? [String: Any])
        let schemes = try XCTUnwrap(components["securitySchemes"] as? [String: Any])
        let bearer = try XCTUnwrap(schemes["bearerAuth"] as? [String: Any])
        XCTAssertEqual(bearer["type"] as? String, "http")
        XCTAssertEqual(bearer["scheme"] as? String, "bearer")
    }

    /// Targeted checks for a YAML document: the same path keys, the
    /// `printer_profile_id` query parameter, and the bearer scheme. Kept as
    /// text-level assertions because the package has no YAML parser; prefer
    /// committing the JSON export so the structural checks above apply.
    private func assertYAMLDocument(_ data: Data) throws {
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for needle in [
            "/api/v1/printer_profiles",
            "/api/v1/colors",
            "printer_profile_id",
            "bearerAuth",
            "scheme: bearer"
        ] {
            XCTAssertTrue(
                text.contains(needle),
                "OpenAPI document at the committed path must describe \"\(needle)\""
            )
        }
    }
}
