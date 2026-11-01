import Foundation
import XCTest

/// Migration guards for adopting the generated OpenAPI client (issue #39).
///
/// These fail until the implementation lands and stay green afterwards: the
/// OpenAPI document published by the `color_matching` service
/// (viamin/color_matching#110, served at `GET /api/v1/openapi.json`) must be
/// committed in the package and must keep covering the endpoints
/// `PaletteAPIClient` consumes, and the package manifest must declare the
/// generator and runtime that build the typed client from it. Refresh
/// procedure and layout conventions: `docs/solver-parity-corpus.md`.
final class GeneratedClientMigrationGuardTests: XCTestCase {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Conventional locations, in preference order, checked so the guard does
    /// not dictate a single layout while still requiring *a* committed spec.
    private static let openAPIDocumentCandidates = [
        "OpenAPI/openapi.yaml",
        "OpenAPI/openapi.json",
        "openapi.yaml",
        "openapi.json",
        "Sources/ColorComposerCore/OpenAPI/openapi.yaml",
    ]

    func testPackageManifestDeclaresOpenAPIGeneratorAndRuntime() throws {
        let manifestURL = Self.packageRoot.appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must run swift-openapi-generator over the committed OpenAPI document (issue #39 deliverable 1)"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must link swift-openapi-runtime for the generated client (issue #39 deliverable 1)"
        )
    }

    func testOpenAPIDocumentIsCommittedAndCoversTheEndpointsTheAppUses() throws {
        guard let documentURL = Self.firstExistingOpenAPIDocument() else {
            XCTFail(
                "No committed OpenAPI document found under ColorComposerCore (looked for \(Self.openAPIDocumentCandidates.joined(separator: ", "))). "
                    + "Fetch the spec served at GET /api/v1/openapi.json and commit it, then generate the client."
            )
            return
        }

        let document = try String(contentsOf: documentURL, encoding: .utf8)
        XCTAssertTrue(document.contains("/api/v1"), "\(documentURL.path): spec must describe the /api/v1 surface")
        XCTAssertTrue(
            document.contains("printer_profiles"),
            "\(documentURL.path): spec must cover GET /api/v1/printer_profiles used by PaletteAPIClient"
        )
        XCTAssertTrue(
            document.contains("colors"),
            "\(documentURL.path): spec must cover GET /api/v1/colors used by PaletteAPIClient"
        )
    }

    private static func firstExistingOpenAPIDocument() -> URL? {
        openAPIDocumentCandidates
            .map { packageRoot.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
