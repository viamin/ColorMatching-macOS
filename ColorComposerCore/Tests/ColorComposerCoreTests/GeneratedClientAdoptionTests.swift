import Foundation
import XCTest

/// Enforces that `ColorComposerCore` actually adopts the generated OpenAPI
/// client (issue #39): the manifest declares `swift-openapi-generator` +
/// `swift-openapi-runtime`, the OpenAPI document and generator config are
/// committed, and the package sources actually use the runtime (the only
/// reliable on-disk marker of the generated client being linked in, since
/// the plugin writes generated output into the build directory).
///
/// These are deliberately structural checks: the behavioral contract of the
/// migrated client is pinned by `PaletteAPIClientContractTests`, which keeps
/// passing through the migration. This suite fails if the migration is
/// claimed without the generated artifacts, so "generated client in place"
/// is machine-checked, not asserted in prose.
///
/// Expected canonical layout (apple/swift-openapi-generator conventions):
///
///     ColorComposerCore/Package.swift
///       - package dependency: apple/swift-openapi-runtime
///       - plugin dependency:  apple/swift-openapi-generator (OpenAPIGenerator)
///       - ColorComposerCore target depends on product OpenAPIRuntime
///     ColorComposerCore/Sources/ColorComposerCore/OpenAPI/
///       - openapi.yaml (or openapi.json)
///       - openapi-generator-config.yaml (or .json)
///     (GeneratedClient.swift / Types.swift are emitted by the plugin into
///      the build directory at build time — they are never committed.)
final class GeneratedClientAdoptionTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ColorComposerCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ColorComposerCore (package root)
    }

    private var openAPIDirectory: URL {
        packageRoot
            .appendingPathComponent("Sources/ColorComposerCore/OpenAPI", isDirectory: true)
    }

    func testPackageManifestDeclaresOpenAPIRuntimeAndGeneratorPlugin() throws {
        let manifest = try String(contentsOf: packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8)

        XCTAssertTrue(manifest.contains("swift-openapi-runtime"), "Package.swift must depend on apple/swift-openapi-runtime")
        XCTAssertTrue(manifest.contains("OpenAPIRuntime"), "the ColorComposerCore target must link the OpenAPIRuntime product")
        XCTAssertTrue(manifest.contains("swift-openapi-generator"), "Package.swift must declare the apple/swift-openapi-generator package for the build plugin")
        XCTAssertTrue(manifest.contains("OpenAPIGenerator"), "the ColorComposerCore target must apply the OpenAPIGenerator plugin")
    }

    func testOpenAPIDocumentIsCommitted() throws {
        let document = try firstExisting(
            in: openAPIDirectory,
            names: ["openapi.yaml", "openapi.json"]
        )

        XCTAssertNotNil(document, "commit the OpenAPI document at Sources/ColorComposerCore/OpenAPI/openapi.yaml (from viamin/color_matching#110)")
    }

    func testOpenAPIGeneratorConfigIsCommitted() throws {
        let config = try firstExisting(
            in: openAPIDirectory,
            names: ["openapi-generator-config.yaml", "openapi-generator-config.json"]
        )

        XCTAssertNotNil(config, "commit the generator config at Sources/ColorComposerCore/OpenAPI/openapi-generator-config.yaml (generate: [client])")
    }

    /// The plugin emits `GeneratedClient.swift` / `Types.swift` into the build
    /// directory, so generated output must NOT be asserted on disk. What a
    /// real adoption always requires — whether `PaletteAPIClient` is migrated
    /// onto the generated `Client` or wraps it — is linking
    /// `OpenAPIRuntime` and using it from the package's own sources.
    func testPackageSourcesAdoptOpenAPIRuntime() throws {
        let sourcesRoot = packageRoot.appendingPathComponent("Sources", isDirectory: true)
        var adopters: [URL] = []
        for url in try swiftFiles(under: sourcesRoot) {
            if try String(contentsOf: url, encoding: .utf8).contains("import OpenAPIRuntime") {
                adopters.append(url)
            }
        }

        XCTAssertFalse(
            adopters.isEmpty,
            "no source under Sources/ imports OpenAPIRuntime — the generated client (which conforms to OpenAPIRuntime protocols) is not adopted yet"
        )
    }

    func testOpenAPIDocumentCoversConsumedEndpoints() throws {
        let documentURL = try XCTUnwrap(
            firstExisting(in: openAPIDirectory, names: ["openapi.yaml", "openapi.json"])
        )
        let document = try String(contentsOf: documentURL, encoding: .utf8)

        XCTAssertTrue(document.contains("/api/v1/printer_profiles"), "spec must describe GET /api/v1/printer_profiles (used by PaletteAPIClient)")
        XCTAssertTrue(document.contains("/api/v1/colors"), "spec must describe GET /api/v1/colors (used by PaletteAPIClient)")
    }

    // MARK: - Helpers

    /// Absolute URLs of every `.swift` file under `root`, recursively.
    private func swiftFiles(under root: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var files: [URL] = []
        while let item = enumerator?.nextObject() {
            guard let url = item as? URL, url.pathExtension == "swift" else { continue }
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    private func firstExisting(in directory: URL, names: [String]) throws -> URL? {
        for name in names {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}
