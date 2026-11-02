import Foundation
import XCTest
@testable import ColorComposerCore

/// Issue #39 adoption guards for the generated OpenAPI client.
///
/// `ColorComposerCore` is being migrated onto a typed client generated from
/// the `color_matching` OpenAPI document (viamin/color_matching#110) via
/// `swift-openapi-generator` + `swift-openapi-runtime`. While
/// `PaletteAPIClient`'s observable behavior is pinned by
/// `PaletteAPIClientBehaviorTests`, these tests fail until the adoption
/// artifacts are actually in place:
///
/// 1. `OpenAPIRuntime` is linked into the package (importable from tests).
/// 2. The OpenAPI document (`openapi.yaml`) is committed next to
///   `Package.swift`, in the layout `swift-openapi-generator` expects.
/// 3. The generator configuration (`openapi-generator-config.yaml`) is
///   committed alongside it.
final class GeneratedClientAdoptionTests: XCTestCase {
    /// `ColorComposerCore/` — the directory holding `Package.swift`, derived
    /// from this file's committed location.
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ColorComposerCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ColorComposerCore
    }

    func testSwiftOpenAPIRuntimeIsLinkedIntoThePackage() {
        #if canImport(OpenAPIRuntime)
        XCTAssertTrue(true)
        #else
        XCTFail(
            "swift-openapi-runtime is not importable from ColorComposerCore tests — issue #39 requires " +
            "the generated-client toolchain (swift-openapi-generator + swift-openapi-runtime) added to " +
            "ColorComposerCore/Package.swift and linked through the ColorComposerCore target."
        )
        #endif
    }

    func testOpenAPIDocumentIsCommittedNextToPackageManifest() throws {
        let document = packageRoot.appendingPathComponent("openapi.yaml")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: document.path),
            "Missing \(document.path) — issue #39 generates the typed client from the OpenAPI document " +
            "published by viamin/color_matching#110; commit it next to Package.swift."
        )

        if FileManager.default.fileExists(atPath: document.path) {
            let contents = try String(contentsOf: document, encoding: .utf8)
            XCTAssertTrue(
                containsOpenAPIVersionDeclaration(contents),
                "The committed document must declare an OpenAPI version (openapi: 3.x) to be usable by swift-openapi-generator."
            )
        }
    }

    func testOpenAPIGeneratorConfigIsCommittedNextToPackageManifest() {
        let config = packageRoot.appendingPathComponent("openapi-generator-config.yaml")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: config.path),
            "Missing \(config.path) — swift-openapi-generator requires a generator config naming the " +
            "generated module next to the OpenAPI document."
        )
    }

    /// Accepts the common spellings (`openapi: 3.1.0`, `openapi: "3.0.3"`)
    /// without pulling in a YAML dependency.
    private func containsOpenAPIVersionDeclaration(_ contents: String) -> Bool {
        let pattern = #"(?m)^openapi:\s*["']?3\."#
        return contents.range(of: pattern, options: .regularExpression) != nil
    }
}
