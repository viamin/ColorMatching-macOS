import Foundation
import XCTest

/// Structural conformance for the generated OpenAPI client (issue #39).
///
/// Deliverable: `swift-openapi-generator` + `swift-openapi-runtime` adopted in
/// `ColorComposerCore`, with a typed client generated from the OpenAPI
/// document published by viamin/color_matching#110, and `PaletteAPIClient`
/// migrated onto it (or wrapping it). These tests fail until the adoption
/// lands; the behavioral side of the migration is pinned separately by
/// `PaletteAPIClientContractTests`, which must pass unchanged before and
/// after the migration.
final class OpenAPIClientMigrationTests: XCTestCase {
    /// .../ColorComposerCore/Tests/ColorComposerCoreTests/<this file>
    /// → the SwiftPM package root (`ColorComposerCore/`).
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testPackageManifestDeclaresOpenAPIGeneratorAndRuntime() throws {
        let manifestURL = packageRoot.appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must depend on swift-openapi-generator (issue #39)"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must depend on swift-openapi-runtime (issue #39)"
        )
        XCTAssertTrue(
            manifest.contains("OpenAPIGenerator"),
            "Package.swift must apply the OpenAPIGenerator build plugin to the ColorComposerCore target (issue #39)"
        )
    }

    func testOpenAPIDocumentIsCommittedForCodeGeneration() throws {
        let documents = try openAPIDocuments(under: packageRoot)

        XCTAssertFalse(
            documents.isEmpty,
            "No OpenAPI document (openapi.yaml / openapi.yml / openapi.json) committed under \(packageRoot.path); " +
                "the generated client is built from it (issue #39, from viamin/color_matching#110)"
        )
    }

    // MARK: - Internals

    /// Files named like an OpenAPI document (`openapi.yaml`, `openapi.json`,
    /// `color_matching_openapi.yml`, …). Skips hidden directories such as
    /// `.build` so stale build artifacts never satisfy the check.
    private func openAPIDocuments(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var matches: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent.lowercased()
            let isOpenAPIDocument = name.contains("openapi")
                && [".yaml", ".yml", ".json"].contains { name.hasSuffix($0) }
            if isOpenAPIDocument {
                matches.append(url)
            }
        }
        return matches
    }
}
