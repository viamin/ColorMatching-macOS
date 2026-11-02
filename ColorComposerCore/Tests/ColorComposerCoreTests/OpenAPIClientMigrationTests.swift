import Foundation
import XCTest

/// Contract tests for the generated OpenAPI client migration (issue #39).
///
/// These intentionally **fail** until the implementation lands:
/// `swift-openapi-generator` + `swift-openapi-runtime` declared in
/// `ColorComposerCore/Package.swift`, and the server's OpenAPI document
/// vendored at `ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.yaml`
/// (the pinned location from `docs/openapi-client-migration.md`, matching the
/// swift-openapi-generator `OpenAPI` directory convention).
///
/// Runtime behavior the migration must preserve is pinned separately — and
/// already passing — in `PaletteAPIClientWireContractTests`,
/// `PaletteAPIClientTests`, `APIDecodingTests`, and `ProfileColorCacheTests`.
final class OpenAPIClientMigrationTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/ColorComposerCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ColorComposerCore
    }

    private func read(_ relativePath: String) throws -> String {
        let url = packageRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Vendored OpenAPI document

    func testOpenAPIDocumentIsVendoredForCodeGeneration() throws {
        let candidates = [
            "Sources/ColorComposerCore/OpenAPI/openapi.yaml",
            "Sources/ColorComposerCore/OpenAPI/openapi.yml",
            "Sources/ColorComposerCore/OpenAPI/openapi.json"
        ]
        let vendored = candidates.filter {
            FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent($0).path)
        }
        XCTAssertFalse(
            vendored.isEmpty,
            """
            No OpenAPI document vendored for code generation. Expected one of:
            \(candidates.map { packageRoot.appendingPathComponent($0).path }.joined(separator: "\n"))
            Source of truth: the server's GET /openapi.json (viamin/color_matching#110).
            See docs/openapi-client-migration.md for the refresh procedure.
            """
        )
    }

    func testVendoredOpenAPIDocumentDescribesConsumedEndpoints() throws {
        let candidates = [
            "Sources/ColorComposerCore/OpenAPI/openapi.yaml",
            "Sources/ColorComposerCore/OpenAPI/openapi.yml",
            "Sources/ColorComposerCore/OpenAPI/openapi.json"
        ]
        let existing = candidates.first {
            FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent($0).path)
        }
        let relativePath = try XCTUnwrap(
            existing,
            "OpenAPI document not vendored yet (issue #39 deliverable 1); nothing to validate."
        )
        let document = try read(relativePath)

        XCTAssertTrue(document.contains("/api/v1/printer_profiles"), "spec must describe GET /api/v1/printer_profiles")
        XCTAssertTrue(document.contains("/api/v1/colors"), "spec must describe GET /api/v1/colors")
        XCTAssertTrue(document.contains("bearerAuth"), "spec must declare the bearerAuth security scheme")
    }

    // MARK: - Package manifest

    func testPackageManifestDeclaresOpenAPIGeneratedClientDependencies() throws {
        let manifest = try read("Package.swift")

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must add the swift-openapi-generator plugin (issue #39 deliverable 1)."
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must add the swift-openapi-runtime dependency (issue #39 deliverable 1)."
        )
    }
}
