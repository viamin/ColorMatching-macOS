import Foundation
import XCTest

/// Structural adoption checks for the generated OpenAPI client (issue #39):
/// `ColorComposerCore` must build its `/api/v1` client from the OpenAPI
/// document published by `color_matching` (viamin/color_matching#110) using
/// `swift-openapi-generator` + `swift-openapi-runtime`.
///
/// These checks are expected to fail until the migration lands; they pin the
/// adoption so the generated client and spec cannot be silently dropped
/// afterwards. The behavioral half of the migration contract — paths, query
/// parameters, headers, error mapping, envelope decoding — is pinned by
/// `PaletteAPIClientTests`, which must stay green through the migration.
final class GeneratedOpenAPIClientAdoptionTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testPackageManifestDeclaresOpenAPIGeneratorAndRuntime() throws {
        let manifest = try String(
            contentsOf: packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "ColorComposerCore/Package.swift must apply the swift-openapi-generator plugin (issue #39)"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "ColorComposerCore/Package.swift must declare the swift-openapi-runtime dependency (issue #39)"
        )
    }

    func testOpenAPIDocumentIsCommittedInsideThePackage() throws {
        let documents = try openAPIDocumentURLs(under: packageRoot)

        XCTAssertFalse(
            documents.isEmpty,
            "no openapi.yaml/openapi.json is committed under ColorComposerCore — commit the /api/v1 document published by color_matching (refresh notes in docs/solver-parity-corpus.md)"
        )
    }

    /// Finds `openapi.{yaml,yml,json}` anywhere in the package, skipping
    /// hidden directories such as `.build` so downloaded dependencies never
    /// satisfy the check.
    private func openAPIDocumentURLs(under root: URL) throws -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var matches: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent.lowercased()
            if name == "openapi.yaml" || name == "openapi.yml" || name == "openapi.json" {
                matches.append(url)
            }
        }
        return matches
    }
}
