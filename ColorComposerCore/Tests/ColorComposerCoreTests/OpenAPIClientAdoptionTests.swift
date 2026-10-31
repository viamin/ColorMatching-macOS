import XCTest
import Foundation

/// Structural guards for the generated-OpenAPI-client adoption (issue #39,/// depends on viamin/color_matching#110).
///
/// `PaletteAPIClient` must be served by a typed client generated from the
/// server's OpenAPI document via `swift-openapi-generator`, with
/// `swift-openapi-runtime` linked — while the behavioral contract it must
/// preserve (per-server/profile disk caching, offline-stale fallback, cached
/// profile fallback, bearer handling) stays pinned by `PaletteAPIClientTests`,
/// `APIDecodingTests`, and `ProfileColorCacheTests`.
///
/// These checks inspect the package layout rather than importing the generated
/// module so they fail with actionable messages during adoption instead of
/// breaking compilation of the whole test target. Expected layout (the
/// swift-openapi-generator convention):
///
/// - `Package.swift` pins `swift-openapi-generator` (plugin) and
///   `swift-openapi-runtime` (library).
/// - an `OpenAPIGenerated` target runs the `OpenAPIGenerator` plugin.
/// - the document lives at `Sources/OpenAPIGenerated/openapi.yaml` (or
///   `.yml`/`.json`) and covers the two `/api/v1` endpoints the client uses
///   today.
/// - package sources reference `OpenAPIGenerated` (migration or wrapper).
final class OpenAPIClientAdoptionTests: XCTestCase {
    private let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // ColorComposerCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // ColorComposerCore package root

    func testPackageDeclaresOpenAPIGeneratorAndRuntimeDependencies() throws {
        let manifest = try readPackageManifest()

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must depend on apple/swift-openapi-generator (client codegen plugin)"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must depend on apple/swift-openapi-runtime (generated client runtime)"
        )
    }

    func testPackageDeclaresAnOpenAPIGeneratedTargetDrivenByThePlugin() throws {
        let manifest = try readPackageManifest()

        XCTAssertTrue(
            manifest.contains("OpenAPIGenerated"),
            "Package.swift must declare an OpenAPIGenerated target the generated client lives in"
        )
        XCTAssertTrue(
            manifest.contains(".plugin(name: \"OpenAPIGenerator\""),
            "the OpenAPIGenerated target must run the OpenAPIGenerator plugin from swift-openapi-generator"
        )
    }

    func testOpenAPIDocumentCoversThePaletteEndpointsTheClientUses() throws {
        let document = try readOpenAPIDocument()

        XCTAssertTrue(
            document.contains("/api/v1/printer_profiles"),
            "the OpenAPI document must describe GET /api/v1/printer_profiles (profiles + connection test)"
        )
        XCTAssertTrue(
            document.contains("/api/v1/colors"),
            "the OpenAPI document must describe GET /api/v1/colors?printer_profile_id=N (palette fetch)"
        )
    }

    func testGeneratedClientIsConsumedByThePackageSources() throws {
        // Only hand-written sources count: the check must prove app code
        // (PaletteAPIClient or its wrapper) consumes the generated client,
        // not merely that a generated file exists.
        let handWritten = try deepSourceFiles(
            under: packageRoot.appendingPathComponent("Sources/ColorComposerCore", isDirectory: true)
        )

        XCTAssertTrue(
            handWritten.contains { source in
                (try? String(contentsOf: source, encoding: .utf8))?.contains("OpenAPIGenerated") == true
            },
            "ColorComposerCore sources must import/use OpenAPIGenerated — PaletteAPIClient migrates to (or wraps) the generated client"
        )
    }

    // MARK: - Helpers

    private func readPackageManifest() throws -> String {
        let url = packageRoot.appendingPathComponent("Package.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Accepts the swift-openapi-generator document conventions
    /// (`openapi.yaml`, `openapi.yml`, or `openapi.json`).
    private func readOpenAPIDocument() throws -> String {
        let candidates = ["openapi.yaml", "openapi.yml", "openapi.json"].map { name in
            packageRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("OpenAPIGenerated", isDirectory: true)
                .appendingPathComponent(name)
        }
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return try String(contentsOf: candidate, encoding: .utf8)
        }
        XCTFail("no OpenAPI document found under Sources/OpenAPIGenerated/ (expected openapi.yaml|.yml|.json)")
        return ""
    }

    private func deepSourceFiles(under directory: URL) throws -> [URL] {
        var files: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                files.append(url)
            }
        }
        return files
    }
}
