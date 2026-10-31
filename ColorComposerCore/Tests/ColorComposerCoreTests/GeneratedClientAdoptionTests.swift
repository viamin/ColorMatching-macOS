import XCTest
@testable import ColorComposerCore

/// Red-phase structural sentinels for issue #39: `ColorComposerCore` must
/// adopt the generated OpenAPI client — `swift-openapi-generator` (build
/// plugin) and `swift-openapi-runtime` (client runtime) declared in the
/// package manifest, plus the OpenAPI document it generates from, committed
/// under the package.
///
/// These checks fail until that implementation lands (this run is the
/// tests-only phase). The *behavior* the migration must preserve — request
/// shapes against `/api/v1`, envelope decoding, error mapping, bearer-token
/// handling — is pinned by `PaletteAPIClientTests`, and the offline disk
/// cache contract by `ProfileColorCacheTests`; those must stay green through
/// the migration whether the generated client replaces or wraps
/// `PaletteAPIClient`.
final class GeneratedClientAdoptionTests: XCTestCase {
    /// `…/ColorComposerCore/Tests/ColorComposerCoreTests/<this file>`
    /// walked up to the `ColorComposerCore` package root.
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
            "issue #39: Package.swift must declare the swift-openapi-generator plugin"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "issue #39: Package.swift must declare the swift-openapi-runtime dependency"
        )
    }

    /// The server publishes its spec at `GET /api/v1/openapi.json`
    /// (viamin/color_matching#110, merged as PR #113 there); the package must
    /// commit a snapshot of that document for generation.
    func testOpenAPIDocumentIsCommittedForGeneration() throws {
        let documents = try committedOpenAPIDocuments()

        XCTAssertFalse(
            documents.isEmpty,
            "issue #39: commit the OpenAPI document snapshot under ColorComposerCore (none of \(documents.count) candidates matched)"
        )
    }

    private func committedOpenAPIDocuments() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: packageRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        )

        return ((enumerator?.allObjects as? [URL]) ?? [])
            .filter { url in
                let path = url.path
                guard !path.contains("/Tests/"), !path.contains("/.build/") else { return false }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                    return false
                }
                let name = url.lastPathComponent.lowercased()
                let namedLikeSpec = name.hasPrefix("openapi") || name.hasPrefix("open_api")
                let specExtension = name.hasSuffix(".yaml") || name.hasSuffix(".yml") || name.hasSuffix(".json")
                return namedLikeSpec && specExtension
            }
    }
}
