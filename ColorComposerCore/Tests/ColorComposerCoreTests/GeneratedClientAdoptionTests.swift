import Foundation
import XCTest
@testable import ColorComposerCore

/// Adoption probes for the generated OpenAPI client (#39).
///
/// The deliverable is repository state, not runtime behavior: `ColorComposerCore`
/// must declare `swift-openapi-generator` + `swift-openapi-runtime`, commit the
/// server's published OpenAPI document (viamin/color_matching#110), and generate
/// a typed client from it that `PaletteAPIClient` then wraps. Until that lands
/// these probes fail — that is the red phase of this change — and once it lands
/// they stay green as a guard against silent removal. The wire-level behavior
/// the migration must preserve is covered separately in
/// `PaletteAPIClientTests` (URLs, headers, status mapping, decoding).
final class GeneratedClientAdoptionTests: XCTestCase {
    private let coreDirectoryName = "ColorComposerCore"

    func testPackageDeclaresOpenAPIGeneratorAndRuntime() throws {
        let manifest = try String(contentsOf: packageManifestURL(), encoding: .utf8)

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "ColorComposerCore/Package.swift must add the swift-openapi-generator plugin dependency (#39)"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "ColorComposerCore/Package.swift must add the swift-openapi-runtime library dependency (#39)"
        )
    }

    /// The server's OpenAPI document (served at `/api/v1/openapi.json`) must be
    /// committed somewhere under the package (outside tests and build output)
    /// so client generation is reproducible without a running server.
    func testOpenAPIDocumentForTheV1APIIsCommitted() throws {
        let documents = try openAPIDocumentURLs()

        XCTAssertFalse(
            documents.isEmpty,
            "No OpenAPI document for /api/v1 found under \(coreDirectoryName)/ (expected a .json/.yaml/.yml "
                + "describing the /api/v1 routes; commit the spec published by viamin/color_matching#110)"
        )
    }

    /// The generated client sources must exist in the package and link against
    /// the OpenAPI runtime — evidence that the typed client is generated (and
    /// not merely that dependencies were declared).
    func testGeneratedClientSourcesImportOpenAPIRuntime() throws {
        let sources = try swiftSourceURLs()
        XCTAssertFalse(sources.isEmpty, "No Swift sources found under the package")

        let importingRuntime = try sources.filter { url in
            try String(contentsOf: url, encoding: .utf8).contains("import OpenAPIRuntime")
        }
        XCTAssertTrue(
            !importingRuntime.isEmpty,
            "No source under \(coreDirectoryName)/Sources imports OpenAPIRuntime; generate the typed client "
                + "with the swift-openapi-generator plugin and route PaletteAPIClient through it"
        )
    }

    // MARK: - Repository layout

    /// `<repo>/ColorComposerCore/Package.swift`, resolved from this test file
    /// (`<repo>/ColorComposerCore/Tests/ColorComposerCoreTests/…`).
    private func packageManifestURL() -> URL {
        packageRootURL().appendingPathComponent("Package.swift")
    }

    private func packageRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ColorComposerCoreTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // ColorComposerCore/
    }

    /// Recursively collects `.swift` files under `Sources/`, skipping hidden
    /// directories and build output.
    private func swiftSourceURLs() throws -> [URL] {
        let sourcesRoot = packageRootURL().appendingPathComponent("Sources", isDirectory: true)
        return try files(under: sourcesRoot, extensions: ["swift"])
    }

    /// Candidate OpenAPI documents under the package root, skipping tests,
    /// fixtures, hidden directories, and `.build` output. A candidate mentions
    /// `openapi` and the `/api/v1` prefix this client consumes.
    private func openAPIDocumentURLs() throws -> [URL] {
        let candidates = try files(
            under: packageRootURL(),
            extensions: ["json", "yaml", "yml"],
            skippedNames: ["Tests", ".build", "Fixtures"]
        )
        return try candidates.filter { url in
            let contents = try String(contentsOf: url, encoding: .utf8)
            return contents.contains("openapi") && contents.contains("/api/v1")
        }
    }

    private func files(
        under root: URL,
        extensions: [String],
        skippedNames: [String] = []
    ) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let skipped = Set(skippedNames)
        var result: [URL] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let next = enumerator?.nextObject() as? URL {
            if skipped.contains(next.lastPathComponent) || next.lastPathComponent.hasPrefix(".") {
                enumerator?.skipDescendants()
                continue
            }
            if extensions.contains(next.pathExtension) {
                result.append(next)
            }
        }
        return result
    }
}
