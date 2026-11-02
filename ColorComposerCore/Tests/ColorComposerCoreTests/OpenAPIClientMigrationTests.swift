import Foundation
import XCTest
#if canImport(OpenAPIRuntime)
import OpenAPIRuntime
#endif

/// Migration gates for adopting the generated OpenAPI client (issue #39).
///
/// These are red until the migration lands and stay green afterwards; they
/// pin the *shape* of the adoption (manifest wiring, canonical document
/// location, spec paths) because the generated types themselves cannot be
/// referenced before generation exists without breaking the whole test target.
/// The wire behavior the migration must preserve is pinned separately in
/// `PaletteAPIClientWireContractTests`. See `docs/OPENAPI_CLIENT_MIGRATION.md`
/// for the contract these tests enforce.
final class OpenAPIClientMigrationTests: XCTestCase {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static var manifestURL: URL { packageRoot.appendingPathComponent("Package.swift") }

    private static var openAPIDocumentURL: URL? {
        let directory = packageRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("ColorComposerCore", isDirectory: true)
            .appendingPathComponent("OpenAPI", isDirectory: true)
        for filename in ["openapi.yaml", "openapi.yml", "openapi.json"] {
            let url = directory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private func manifestSource(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let url = Self.manifestURL
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("Package manifest not found at \(url.path)", file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        return source
    }

    func testManifestDeclaresSwiftOpenAPIRuntimeDependency() throws {
        let manifest = try manifestSource()

        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must depend on apple/swift-openapi-runtime (see docs/OPENAPI_CLIENT_MIGRATION.md)"
        )
        XCTAssertTrue(
            manifest.contains("OpenAPIRuntime"),
            "Package.swift must link the OpenAPIRuntime product into the client target"
        )
    }

    func testManifestWiresOpenAPIGeneratorPlugin() throws {
        let manifest = try manifestSource()

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must depend on apple/swift-openapi-generator (see docs/OPENAPI_CLIENT_MIGRATION.md)"
        )
        XCTAssertTrue(
            manifest.contains("OpenAPIGenerator"),
            "Package.swift must apply the OpenAPIGenerator plugin to the client target"
        )
    }

    func testOpenAPIDocumentIsCommittedAtCanonicalPath() throws {
        let url = try XCTUnwrap(
            Self.openAPIDocumentURL,
            "OpenAPI document missing at Sources/ColorComposerCore/OpenAPI/openapi.{yaml,yml,json}; "
                + "copy it from the color_matching server (viamin/color_matching#110)"
        )

        let document = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(document.isEmpty)

        XCTAssertTrue(
            document.contains("/api/v1/printer_profiles"),
            "the committed OpenAPI document must describe GET /api/v1/printer_profiles"
        )
        XCTAssertTrue(
            document.contains("/api/v1/colors"),
            "the committed OpenAPI document must describe GET /api/v1/colors"
        )
    }

    func testOpenAPIRuntimeIsLinkedIntoThePackage() {
        #if canImport(OpenAPIRuntime)
        // The migration is in place; the behavioral contract is enforced by
        // PaletteAPIClientWireContractTests.
        #else
        XCTFail(
            "swift-openapi-runtime is not linked into ColorComposerCore yet; "
                + "the generated-client migration (issue #39) is still outstanding"
        )
        #endif
    }
}
