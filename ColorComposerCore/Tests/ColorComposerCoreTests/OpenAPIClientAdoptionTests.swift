import Foundation
import XCTest

/// Conformance tests for the generated OpenAPI client adoption (#39).
///
/// These are deliberately structural: they fail until `ColorComposerCore`
/// declares `swift-openapi-generator` + `swift-openapi-runtime` (viamin/color_matching#110),
/// commits the OpenAPI document, and generates the typed client sources that
/// `PaletteAPIClient` is migrated onto. Behavioral parity of the migration is
/// pinned separately by `PaletteAPIClientTests`, `PaletteAPIClientWireContractTests`,
/// `APIDecodingTests`, and `ProfileColorCacheTests` (disk cache / offline-stale
/// / cached-profile fallback).
final class OpenAPIClientAdoptionTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)          // .../ColorComposerCore/Tests/ColorComposerCoreTests/OpenAPIClientAdoptionTests.swift
            .deletingLastPathComponent()         // Tests/ColorComposerCoreTests
            .deletingLastPathComponent()         // Tests
            .deletingLastPathComponent()         // ColorComposerCore (package root)
    }

    /// The package manifest must declare both the runtime library and the
    /// generator (plugin dependency), per the swift-openapi-generator adoption
    /// guide.
    func testPackageManifestDeclaresOpenAPIRuntimeAndGenerator() throws {
        let manifest = try String(
            contentsOf: packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must depend on apple/swift-openapi-runtime (#39)"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must declare the swift-openapi-generator plugin (#39)"
        )
    }

    /// The OpenAPI document describing `color_matching` `/api/v1`
    /// (viamin/color_matching#110) must be committed inside the package.
    func testOpenAPIDocumentIsCommittedToThePackage() throws {
        let documents = filesInPackageRoot(matching: { name in
            let lower = name.lowercased()
            return (lower.hasPrefix("openapi") || lower.hasSuffix(".openapi.yaml") || lower.hasSuffix(".openapi.json"))
                && (lower.hasSuffix(".yaml") || lower.hasSuffix(".yml") || lower.hasSuffix(".json"))
        })
        XCTAssertFalse(
            documents.isEmpty,
            "No OpenAPI document found under \(packageRoot.path) — commit the spec from viamin/color_matching#110 (#39)"
        )
    }

    /// The generated typed client sources (swift-openapi-generator emits
    /// `OpenAPI.swift` into the configured target) must exist in Sources.
    func testGeneratedClientSourcesExist() throws {
        let sourcesURL = packageRoot.appendingPathComponent("Sources")
        let generated = filesUnder(sourcesURL, matching: { $0 == "OpenAPI.swift" })
        XCTAssertFalse(
            generated.isEmpty,
            "No generated OpenAPI client sources found under Sources/ — run swift-openapi-generator (#39)"
        )
    }

    // MARK: - File search

    private func filesInPackageRoot(
        matching predicate: @escaping (String) -> Bool
    ) -> [URL] {
        filesUnder(packageRoot, matching: predicate)
    }

    private func filesUnder(
        _ root: URL,
        matching predicate: @escaping (String) -> Bool
    ) -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var hits: [URL] = []
        while let next = enumerator?.nextObject() as? URL {
            let path = next.path
            if path.contains("/.build/") || path.contains("/.git/") { continue }
            guard let name = try? next.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, name else {
                continue
            }
            if predicate(lastPathComponent(of: path)) {
                hits.append(next)
            }
        }
        return hits
    }

    private func lastPathComponent(of path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
