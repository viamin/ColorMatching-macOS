import Foundation
import XCTest

/// Structural gates for the generated OpenAPI client migration (issue #39).
///
/// These tests deliberately reference no generated types — the corpus of
/// behavior the client must preserve lives in `PaletteAPIContractTests` and
/// `ProfileColorCacheTests`, which keep passing through the migration. What
/// they pin is the presence of the two integration artifacts the issue makes
/// deliverables:
///
/// 1. `ColorComposerCore/Package.swift` declares `swift-openapi-generator`
///    (the codegen plugin) and `swift-openapi-runtime` (the runtime the
///    generated code links).
/// 2. The OpenAPI document describing `/api/v1` is committed where the plugin
///    can consume it, and it covers the two endpoints `PaletteAPIClient`
///    uses today (`/api/v1/printer_profiles`, `/api/v1/colors`).
///
/// They fail until the implementation run lands those artifacts — that is
/// their red-phase purpose — and stay green afterwards so neither half can
/// silently regress (a doc that drops an endpoint, or a manifest that drops
/// the runtime, both fail here).
final class OpenAPIClientIntegrationTests: XCTestCase {
    private let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    private let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func testPackageManifestDeclaresOpenAPIGeneratorAndRuntime() throws {
        let manifestURL = packageRoot.appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)

        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "ColorComposerCore/Package.swift must link swift-openapi-runtime for the generated client"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "ColorComposerCore/Package.swift must run the swift-openapi-generator plugin over the OpenAPI document"
        )
    }

    func testOpenAPIDocumentIsCommittedAndCoversConsumedEndpoints() throws {
        let document = try findOpenAPIDocument()
        let contents = try String(contentsOf: document, encoding: .utf8)

        XCTAssertTrue(
            contents.contains("openapi:") || contents.contains("\"openapi\""),
            "\(document.path) does not look like an OpenAPI document (no `openapi` version key)"
        )
        XCTAssertTrue(
            contents.contains("printer_profiles"),
            "\(document.path) must describe GET /api/v1/printer_profiles — PaletteAPIClient depends on it"
        )
        XCTAssertTrue(
            contents.contains("colors"),
            "\(document.path) must describe GET /api/v1/colors — PaletteAPIClient depends on it"
        )
    }

    private func findOpenAPIDocument(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let candidates = [
            packageRoot.appendingPathComponent("openapi.yaml"),
            packageRoot.appendingPathComponent("openapi.yml"),
            packageRoot.appendingPathComponent("openapi.json"),
            packageRoot.appendingPathComponent("OpenAPI/openapi.yaml"),
            packageRoot.appendingPathComponent("OpenAPI/openapi.yml"),
            packageRoot.appendingPathComponent("OpenAPI/openapi.json"),
            packageRoot.appendingPathComponent("Sources/ColorComposerCore/OpenAPI/openapi.yaml"),
            packageRoot.appendingPathComponent("Sources/ColorComposerCore/OpenAPI/openapi.yml"),
            packageRoot.appendingPathComponent("Sources/ColorComposerCore/OpenAPI/openapi.json"),
            repoRoot.appendingPathComponent("openapi.yaml"),
            repoRoot.appendingPathComponent("openapi.yml"),
            repoRoot.appendingPathComponent("openapi.json")
        ]

        guard let document = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            let searched = candidates.map(\.path).joined(separator: "\n  ")
            XCTFail(
                "No OpenAPI document found. Issue #39 commits the spec from viamin/color_matching#110 for codegen. Searched:\n  \(searched)",
                file: file,
                line: line
            )
            throw CocoaError(.fileNoSuchFile)
        }
        return document
    }
}
