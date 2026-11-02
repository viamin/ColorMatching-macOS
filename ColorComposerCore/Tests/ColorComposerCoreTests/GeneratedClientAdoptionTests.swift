import Foundation
import XCTest

/// Adoption guard for the generated OpenAPI client (issue #39).
///
/// Issue #39 requires `ColorComposerCore` to generate its typed API client
/// from the server's published OpenAPI document (viamin/color_matching#110,
/// served at `GET /api/v1/openapi.json`) using `swift-openapi-generator` +
/// `swift-openapi-runtime`. These tests intentionally fail until that
/// migration lands, and afterwards protect against silently dropping the
/// vendored document or the generator dependencies.
///
/// The behavioral half of the migration contract — request paths, headers,
/// decoding, and error mapping — is pinned by
/// `PaletteAPIClientContractTests`, which must stay green across the
/// migration so the disk-cache/offline-stale behavior above it is unaffected.
final class GeneratedClientAdoptionTests: XCTestCase {
    /// `<repo root>/ColorComposerCore`, resolved from this file's location.
    private static var packageDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ColorComposerCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ColorComposerCore
    }

    private static var packageManifest: URL {
        packageDirectory.appendingPathComponent("Package.swift")
    }

    func testOpenAPIDocumentIsVendoredForClientGeneration() {
        let candidates = ["openapi.yaml", "openapi.yml", "openapi.json"]
            .map { packageDirectory.appendingPathComponent($0) }
        let existing = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }

        XCTAssertFalse(
            existing.isEmpty,
            "No OpenAPI document found: expected one of \(candidates.map(\.lastPathComponent)) in ColorComposerCore/. " +
            "Fetch the spec from GET /api/v1/openapi.json (viamin/color_matching#110) and commit it."
        )
    }

    func testPackageManifestDeclaresOpenAPIGeneratorAndRuntime() throws {
        let manifest = try String(contentsOf: Self.packageManifest, encoding: .utf8)

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "ColorComposerCore/Package.swift must declare swift-openapi-generator (issue #39)"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "ColorComposerCore/Package.swift must declare swift-openapi-runtime (issue #39)"
        )
    }
}
