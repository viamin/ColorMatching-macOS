import Foundation
import XCTest

/// Migration guards for issue #39: `ColorComposerCore` must consume a typed
/// client generated from the `color_matching` OpenAPI document
/// (viamin/color_matching#110) via `swift-openapi-generator` +
/// `swift-openapi-runtime`.
///
/// These tests intentionally inspect the package manifest and the committed
/// OpenAPI document on disk instead of referencing generated types, so the
/// suite still compiles before the migration lands. They are the red-phase
/// demonstration of the missing deliverable: each fails until
/// `PaletteAPIClient` is backed by the generated client. The behavioral
/// contract the migration must preserve is pinned separately in
/// `PaletteAPIClientContractTests`.
final class OpenAPIClientMigrationTests: XCTestCase {
    private static let packageDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ColorComposerCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // ColorComposerCore

    private static let openAPIDocumentCandidates = [
        "OpenAPI/openapi.yaml",
        "OpenAPI/openapi.yml",
        "OpenAPI/openapi.json",
        "Sources/ColorComposerCore/OpenAPI/openapi.yaml",
        "Sources/ColorComposerCore/OpenAPI/openapi.json",
        "openapi.yaml",
        "openapi.json"
    ]

    private func readPackageManifest() throws -> String {
        let url = Self.packageDirectory.appendingPathComponent("Package.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func findOpenAPIDocument() -> URL? {
        Self.openAPIDocumentCandidates
            .map { Self.packageDirectory.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func testPackageManifestDeclaresOpenAPIGeneratorAndRuntime() throws {
        let manifest = try readPackageManifest()

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Issue #39: ColorComposerCore/Package.swift must declare the swift-openapi-generator plugin so the typed client is generated at build time."
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Issue #39: ColorComposerCore/Package.swift must declare the swift-openapi-runtime dependency the generated client links against."
        )
    }

    func testOpenAPIDocumentIsCommittedAndCoversConsumedEndpoints() throws {
        guard let documentURL = findOpenAPIDocument() else {
            return XCTFail(
                "Issue #39: no OpenAPI document found under ColorComposerCore (searched: \(Self.openAPIDocumentCandidates.joined(separator: ", "))). Commit the document published by viamin/color_matching#110 so the client can be generated from it."
            )
        }

        let document = try String(contentsOf: documentURL, encoding: .utf8)
        XCTAssertTrue(
            document.contains("printer_profiles"),
            "The committed OpenAPI document must describe GET /api/v1/printer_profiles — PaletteAPIClient's profile-list endpoint."
        )
        XCTAssertTrue(
            document.contains("colors"),
            "The committed OpenAPI document must describe GET /api/v1/colors — PaletteAPIClient's colors endpoint."
        )
    }
}
