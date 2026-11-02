import Foundation
import XCTest

/// Build-level adoption checks for the generated OpenAPI client (issue #39).
///
/// These deliberately inspect the package on disk instead of compiling
/// against generated symbols: they fail red until `ColorComposerCore`
/// declares the swift-openapi-generator plugin + swift-openapi-runtime
/// library and commits the OpenAPI document those dependencies generate the
/// typed client from. The behavioral side of the migration (requests, error
/// mapping, decoding) is pinned by `PaletteAPIWireContractTests`; the
/// offline side by `OfflineFallbackAfterFetchTests` and
/// `ProfileColorCacheTests`.
final class OpenAPIClientAdoptionTests: XCTestCase {
    /// `…/ColorComposerCore/Tests/ColorComposerCoreTests/OpenAPIClientAdoptionTests.swift`
    /// → package root `…/ColorComposerCore`.
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The manifest must wire up both halves of code generation: the
    /// generator plugin (build-time) and the runtime library (linked).
    func testPackageManifestDeclaresOpenAPIGeneratorAndRuntime() throws {
        let manifest = try String(
            decoding: Data(contentsOf: packageRoot.appendingPathComponent("Package.swift")),
            as: UTF8.self
        )

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must add the swift-openapi-generator plugin so the typed client is generated at build time"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must link swift-openapi-runtime for the generated client"
        )
    }

    /// The OpenAPI document the client is generated from must be committed
    /// with the package (not fetched at build time), and it must describe the
    /// two `/api/v1` endpoints `PaletteAPIClient` consumes.
    func testOpenAPIDocumentIsCommittedAndCoversConsumedEndpoints() throws {
        let documentURL = try XCTUnwrap(
            findOpenAPIDocument(),
            "expected an OpenAPI document (openapi.yaml / openapi.yml / openapi.json) committed under the ColorComposerCore package"
        )
        let document = try String(decoding: Data(contentsOf: documentURL), as: UTF8.self)

        XCTAssertTrue(
            document.contains("/api/v1/printer_profiles"),
            "\(documentURL.path) must describe GET /api/v1/printer_profiles — the profiles endpoint PaletteAPIClient consumes"
        )
        XCTAssertTrue(
            document.contains("/api/v1/colors"),
            "\(documentURL.path) must describe GET /api/v1/colors — the colors endpoint PaletteAPIClient consumes"
        )
    }

    /// Searches the package (skipping build output, tests, and VCS metadata)
    /// for a committed OpenAPI document by its conventional file name.
    private func findOpenAPIDocument() -> URL? {
        let documentNames: Set<String> = ["openapi.yaml", "openapi.yml", "openapi.json"]
        let skippedNames: Set<String> = ["Tests", ".build", "DerivedData", ".git", "plugins"]

        guard let enumerator = FileManager.default.enumerator(
            at: packageRoot,
            includingPropertiesForKeys: nil
        ) else { return nil }

        for case let url as URL in enumerator {
            if skippedNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            if documentNames.contains(url.lastPathComponent) {
                return url
            }
        }
        return nil
    }
}
