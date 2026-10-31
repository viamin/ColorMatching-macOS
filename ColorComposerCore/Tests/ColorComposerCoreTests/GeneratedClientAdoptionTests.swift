import Foundation
import XCTest
@testable import ColorComposerCore

/// Packaging guards for the generated OpenAPI client adoption (issue #39):
/// once the migration lands, `ColorComposerCore` must declare
/// `swift-openapi-generator` + `swift-openapi-runtime` in its manifest and
/// ship generated/wrapped client sources that link the runtime.
///
/// These deliberately fail before the migration (red phase): the adoption
/// criterion is a packaging fact, and this is the smallest check that pins it
/// without breaking compilation of the whole test target (a compile-time
/// `import OpenAPIRuntime` would). The behavioral wire contract the generated
/// client must preserve is pinned separately in
/// `PaletteAPIClientContractTests`.
final class GeneratedClientAdoptionTests: XCTestCase {
    /// …/Tests/ColorComposerCoreTests/<this file> → package root.
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func testPackageManifestDeclaresOpenAPIGeneratorAndRuntime() throws {
        let manifestURL = Self.packageRoot.appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must declare swift-openapi-generator (dependency or build-tool plugin)"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must declare the swift-openapi-runtime dependency"
        )
    }

    func testPackageSourcesLinkTheOpenAPIRuntime() throws {
        let sources = try Self.swiftSources(in: Self.packageRoot)
        XCTAssertFalse(sources.isEmpty, "expected package Swift sources to exist")

        let importing = try sources.filter { url in
            try String(contentsOf: url, encoding: .utf8).contains("import OpenAPIRuntime")
        }
        XCTAssertFalse(
            importing.isEmpty,
            "expected a package source file (the generated client or its wrapper) to import OpenAPIRuntime"
        )
    }

    /// All `.swift` files under the package root except the build cache, VCS
    /// metadata, and the test sources (tests must not satisfy the adoption
    /// check — only shipped package code counts).
    private static func swiftSources(in root: URL) throws -> [URL] {
        let fileManager = FileManager.default
        let excludedDirectories: Set<String> = [".build", ".git", "Tests"]
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var sources: [URL] = []
        for case let url as URL in enumerator {
            if url.hasDirectoryPath {
                if url.lastPathComponent.hasPrefix(".") || excludedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if url.pathExtension == "swift" {
                sources.append(url)
            }
        }
        return sources
    }
}
