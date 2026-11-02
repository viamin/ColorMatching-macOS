import XCTest
#if canImport(OpenAPIRuntime)
import OpenAPIRuntime
#endif

/// Structural checks for the generated OpenAPI client migration (issue #39):
/// `ColorComposerCore` must carry the committed OpenAPI document, declare the
/// `swift-openapi-generator` + `swift-openapi-runtime` dependencies, and link
/// the runtime so `PaletteAPIClient` can be migrated onto the generated typed
/// client without changing its wire behavior (that behavior is pinned
/// separately by `PaletteAPIClientTests`). See docs/openapi-client-migration.md
/// for the committed layout these checks enforce.
final class OpenAPIClientMigrationTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relativePath: String) throws -> String {
        let url = packageRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        return String(decoding: data, as: UTF8.self)
    }

    func testOpenAPIDocumentIsCommittedForColorMatchingV1() throws {
        let candidates = ["OpenAPI/openapi.yaml", "OpenAPI/openapi.yml", "OpenAPI/openapi.json"]
        var found: String?
        for relative in candidates where found == nil {
            if let text = try? read(relative), !text.isEmpty {
                found = text
            }
        }

        let document = try XCTUnwrap(
            found,
            "No OpenAPI document found under ColorComposerCore/OpenAPI/ (expected one of: \(candidates.joined(separator: ", ")))"
        )

        XCTAssertTrue(document.contains("printer_profiles"), "document must describe GET /printer_profiles")
        XCTAssertTrue(document.contains("colors"), "document must describe GET /colors")
        XCTAssertTrue(
            document.contains("api/v1"),
            "document must keep the versioned /api/v1 base path PaletteAPIClient uses today"
        )
    }

    func testPackageManifestDeclaresOpenAPIGeneratorAndRuntime() throws {
        let manifest = try read("Package.swift")

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must declare the swift-openapi-generator dependency"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must declare the swift-openapi-runtime dependency"
        )
    }

    func testOpenAPIRuntimeModuleIsLinked() {
        #if canImport(OpenAPIRuntime)
        XCTAssertTrue(true)
        #else
        XCTFail(
            "swift-openapi-runtime is not resolvable from the ColorComposerCore tests; "
                + "the generated-client dependencies are not wired into the package yet (issue #39)"
        )
        #endif
    }
}
