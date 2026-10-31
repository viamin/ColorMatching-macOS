import XCTest
@testable import ColorComposerCore

/// Red-phase structural contract for the generated OpenAPI client
/// (issue #39, deliverable 1).
///
/// These tests fail until `ColorComposerCore` adopts
/// `swift-openapi-generator` + `swift-openapi-runtime` with a committed
/// OpenAPI document, and pass once the artifacts exist at the locations
/// documented in `docs/issue-39-verification-plan.md`:
///
/// - `Sources/ColorComposerCore/OpenAPI/openapi.yaml` (or `.json`) — the
///   spec published by viamin/color_matching#110,
/// - an `openapi-generator.yaml` requesting `client` generation, and
/// - `Package.swift` wiring the `OpenAPIGenerator` plugin and runtime.
///
/// They are deliberately structural: the *behavioral* half of the contract
/// (endpoints, query parameters, bearer-token header, envelope decoding,
/// error mapping, disk-cache/offline fallback) is pinned by
/// `PaletteAPIClientTests` and `ProfileColorCacheTests`, which the
/// migration must keep green.
final class OpenAPIClientContractTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ColorComposerCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ColorComposerCore (package root)
    }

    private func readText(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func existingDocumentURL() -> URL? {
        ["yaml", "yml", "json"]
            .map { packageRoot.appendingPathComponent("Sources/ColorComposerCore/OpenAPI/openapi.\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The OpenAPI document describing `/api/v1` must be committed so the
    /// generated client builds from a pinned, reviewable contract.
    func testOpenAPIDocumentIsCommitted() throws {
        guard let documentURL = existingDocumentURL() else {
            return XCTFail(
                "No OpenAPI document found under Sources/ColorComposerCore/OpenAPI/. "
                    + "Commit the spec published by viamin/color_matching#110 "
                    + "(see docs/issue-39-verification-plan.md)"
            )
        }

        let document = try readText(documentURL)
        XCTAssertFalse(document.isEmpty, "The committed OpenAPI document must not be empty")

        // Both `/api/v1` surfaces PaletteAPIClient consumes today must be
        // described; anything beyond them is out of scope for this app.
        XCTAssertTrue(
            document.contains("/api/v1/printer_profiles"),
            "The OpenAPI document must describe GET /api/v1/printer_profiles"
        )
        XCTAssertTrue(
            document.contains("/api/v1/colors"),
            "The OpenAPI document must describe GET /api/v1/colors"
        )
    }

    /// The package manifest must wire the generator plugin and runtime so the
    /// typed client is produced from the committed document on every build.
    func testPackageManifestWiresOpenAPIGenerator() throws {
        let manifestURL = packageRoot.appendingPathComponent("Package.swift")
        let manifest: String
        do {
            manifest = try readText(manifestURL)
        } catch {
            return XCTFail("Package.swift is missing at \(manifestURL.path)")
        }

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must depend on apple/swift-openapi-generator"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must depend on apple/swift-openapi-runtime"
        )
        XCTAssertTrue(
            manifest.contains("OpenAPIGenerator"),
            "Package.swift must attach the OpenAPIGenerator plugin to the ColorComposerCore target"
        )
    }

    /// The generator config must request client generation (this app only
    /// consumes the API; it does not serve it).
    func testOpenAPIGeneratorConfigRequestsClientGeneration() throws {
        let candidates = [
            packageRoot.appendingPathComponent("openapi-generator.yaml"),
            packageRoot.appendingPathComponent("Sources/ColorComposerCore/OpenAPI/openapi-generator.yaml")
        ]
        guard let configURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return XCTFail(
                "No openapi-generator.yaml found at the package root or next to the document. "
                    + "It must set generate: [client] (see docs/issue-39-verification-plan.md)"
            )
        }

        let config = try readText(configURL)
        XCTAssertTrue(
            config.contains("client"),
            "openapi-generator.yaml must request client generation"
        )
        XCTAssertFalse(
            config.contains("server"),
            "This app is a consumer only; openapi-generator.yaml must not generate a server"
        )
    }
}
