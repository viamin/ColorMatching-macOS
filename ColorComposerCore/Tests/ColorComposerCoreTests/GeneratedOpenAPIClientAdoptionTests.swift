import Foundation
import XCTest

/// Milestone checks for adopting the generated OpenAPI client (issue #39).
///
/// These go green exactly when the migration lands, following the standard
/// `apple/swift-openapi-generator` layout (documented in
/// `docs/generated-openapi-client.md`):
///
/// 1. `ColorComposerCore/Package.swift` pulls in `swift-openapi-generator`
///    (as a build plugin) and `swift-openapi-runtime` (as a library).
/// 2. The OpenAPI document lives at
///    `ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.yaml`.
/// 3. At least one source file in the target is wired to the generated
///    client via `OpenAPIRuntime`.
///
/// Behavioral preservation (same URLs, envelopes, auth, error mapping) is
/// pinned separately by `PaletteAPIClientContractTests` and
/// `ProfileColorCacheTests`.
final class GeneratedOpenAPIClientAdoptionTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/ColorComposerCoreTests
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // ColorComposerCore/
    }

    private func read(_ relativePath: String) throws -> String {
        let url = packageRoot.appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("Missing required file for the generated-client migration: \(relativePath)")
            throw CocoaError(.fileNoSuchFile)
        }
        return text
    }

    private func swiftSources() throws -> [URL] {
        let sourcesRoot = packageRoot.appendingPathComponent("Sources/ColorComposerCore")
        guard let enumerator = FileManager.default
            .enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)
        else { return [] }
        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
    }

    func testPackageManifestDeclaresOpenAPIGeneratorAndRuntime() throws {
        let manifest = try read("Package.swift")

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must depend on apple/swift-openapi-generator"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must depend on apple/swift-openapi-runtime"
        )
        XCTAssertTrue(
            manifest.contains(".plugin(name: \"OpenAPIGenerator\""),
            "The ColorComposerCore target must apply the OpenAPIGenerator build plugin"
        )
        XCTAssertTrue(
            manifest.contains(".product(name: \"OpenAPIRuntime\""),
            "The ColorComposerCore target must link the OpenAPIRuntime product"
        )
    }

    func testOpenAPIDocumentIsCommittedInStandardLocation() throws {
        let document = try read("Sources/ColorComposerCore/OpenAPI/openapi.yaml")

        XCTAssertTrue(
            document.contains("openapi: 3"),
            "The committed document must be OpenAPI 3.x"
        )
        XCTAssertTrue(
            document.contains("/api/v1/printer_profiles"),
            "The document must describe GET /api/v1/printer_profiles"
        )
        XCTAssertTrue(
            document.contains("/api/v1/colors"),
            "The document must describe GET /api/v1/colors"
        )
        XCTAssertTrue(
            document.contains("bearerAuth"),
            "The document must declare the bearerAuth security scheme used by PaletteAPIClient"
        )
    }

    func testGeneratedClientRuntimeIsWiredIntoTheTargetSources() throws {
        let sources = try swiftSources()
        XCTAssertFalse(sources.isEmpty, "ColorComposerCore sources not found")

        let wired = sources.filter {
            (try? String(contentsOf: $0, encoding: .utf8))?.contains("OpenAPIRuntime") ?? false
        }
        XCTAssertFalse(
            wired.isEmpty,
            "No source file references OpenAPIRuntime; PaletteAPIClient must be migrated to "
                + "(or wrapped around) the generated client"
        )
    }
}
