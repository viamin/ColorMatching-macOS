import Foundation
import XCTest

/// Contract tests for the generated OpenAPI client migration (issue #39).
///
/// These stay red until `ColorComposerCore` adopts `swift-openapi-generator` /
/// `swift-openapi-runtime` with a committed OpenAPI document exported from the
/// `color_matching` server (viamin/color_matching#110), while
/// `PaletteAPIClientMigrationWireTests` keeps the existing wire behavior
/// pinned so the migration cannot change what goes over the wire.
final class OpenAPIClientMigrationTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var openAPIDocumentURL: URL? {
        let directory = packageRoot
            .appendingPathComponent("Sources/ColorComposerCore/OpenAPI", isDirectory: true)
        return ["yaml", "yml", "json"].lazy
            .map { directory.appendingPathComponent("openapi.\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func testOpenAPIDocumentIsCommittedForGeneratedClient() {
        XCTAssertNotNil(
            openAPIDocumentURL,
            "No OpenAPI document found at Sources/ColorComposerCore/OpenAPI/openapi.{yaml,yml,json}. " +
                "Export the spec from color_matching (viamin/color_matching#110) and commit it — " +
                "see docs/solver-parity-corpus.md#openapi-document."
        )
    }

    func testOpenAPIDocumentDescribesPaletteAPIV1Contract() throws {
        let documentURL = try XCTUnwrap(
            openAPIDocumentURL,
            "Commit the OpenAPI document (viamin/color_matching#110) before asserting its contents."
        )
        let document = try String(contentsOf: documentURL, encoding: .utf8).lowercased()

        let required: [(needle: String, meaning: String)] = [
            ("/api/v1/printer_profiles", "printer profiles endpoint"),
            ("/api/v1/colors", "colors endpoint"),
            ("printer_profile_id", "colors query parameter"),
            ("bearerauth", "bearer authentication scheme"),
        ]
        for item in required {
            XCTAssertTrue(
                document.contains(item.needle),
                "OpenAPI document \(documentURL.lastPathComponent) is missing \(item.meaning) (`\(item.needle)`)."
            )
        }
    }

    func testPackageManifestDeclaresOpenAPIGeneratorAndRuntime() throws {
        let manifest = try String(
            contentsOf: packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must declare swift-openapi-generator (issue #39)."
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must declare swift-openapi-runtime (issue #39)."
        )
    }
}
