import Foundation
import XCTest
@testable import ColorComposerCore

/// Build-level contract for issue #39 deliverable 1: `ColorComposerCore`
/// consumes the `color_matching` OpenAPI document through
/// `apple/swift-openapi-generator` + `apple/swift-openapi-runtime` and ships
/// the generated typed client alongside `PaletteAPIClient`.
///
/// These are red while the migration is outstanding. The runtime behavior
/// `PaletteAPIClient` must preserve across the migration (endpoints, headers,
/// error mapping, decoding, disk-cache compatibility) is pinned separately by
/// `PaletteAPIClientMigrationContractTests`.
///
/// The paths asserted here are the conventional swift-openapi-generator
/// layout (`OpenAPI/openapi.yaml` document, `OpenAPIGenerated/` output). If
/// the implementation deliberately chooses a different layout, update these
/// assertions in the same change — do not delete them.
final class OpenAPIGeneratedClientTests: XCTestCase {
    private static var testDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    /// `<repo>/ColorComposerCore`
    private static var packageRoot: URL {
        testDirectory
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // ColorComposerCore/
    }

    private func requireTextFile(
        _ relativePath: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let url = Self.packageRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Missing \(relativePath) (expected at \(url.path)) — issue #39 requires the generated OpenAPI client to be wired into ColorComposerCore", file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func requireExistingPath(
        _ relativePath: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let url = Self.packageRoot.appendingPathComponent(relativePath)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "Missing \(relativePath) (expected at \(url.path)) — issue #39 requires the generated OpenAPI client to be wired into ColorComposerCore",
            file: file,
            line: line
        )
    }

    /// The package manifest must declare both halves of the OpenAPI toolchain:
    /// the generator plugin (build-time) and the runtime library.
    func testPackageDeclaresOpenAPIGeneratorAndRuntime() throws {
        let manifest = try requireTextFile("Package.swift")

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must depend on apple/swift-openapi-generator and apply its plugin to the ColorComposerCore target",
            file: #filePath,
            line: #line
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must link apple/swift-openapi-runtime into ColorComposerCore",
            file: #filePath,
            line: #line
        )
    }

    /// The OpenAPI document describing `/api/v1` (published by
    /// viamin/color_matching#110, served at `GET /api/v1/openapi.json`) must
    /// be committed and must describe both operations `PaletteAPIClient`
    /// consumes today — no new API surfaces.
    func testOpenAPIDocumentIsCommittedAndCoversConsumedEndpoints() throws {
        let yaml = Self.packageRoot
            .appendingPathComponent("Sources/ColorComposerCore/OpenAPI/openapi.yaml")
        let json = Self.packageRoot
            .appendingPathComponent("Sources/ColorComposerCore/OpenAPI/openapi.json")

        let document: String
        if FileManager.default.fileExists(atPath: yaml.path) {
            document = try String(contentsOf: yaml, encoding: .utf8)
        } else if FileManager.default.fileExists(atPath: json.path) {
            document = try String(contentsOf: json, encoding: .utf8)
        } else {
            XCTFail("Missing Sources/ColorComposerCore/OpenAPI/openapi.yaml (or .json) — vendor the /api/v1 OpenAPI document from the color_matching server (viamin/color_matching#110)")
            throw CocoaError(.fileNoSuchFile)
        }

        XCTAssertTrue(document.contains("openapi"), "the committed document must be an OpenAPI description")
        XCTAssertTrue(document.contains("/printer_profiles"), "the document must describe GET /printer_profiles")
        XCTAssertTrue(document.contains("/colors"), "the document must describe GET /colors")
    }

    /// swift-openapi-generator's output (`Types.swift`, `Client.swift`, …)
    /// must be committed under the conventional `OpenAPIGenerated/` directory
    /// so `swift test` builds the typed client without network access.
    func testGeneratedClientSourcesAreCommitted() throws {
        try requireExistingPath("Sources/ColorComposerCore/OpenAPIGenerated")
        try requireExistingPath("Sources/ColorComposerCore/OpenAPIGenerated/Types.swift")
        try requireExistingPath("Sources/ColorComposerCore/OpenAPIGenerated/Client.swift")
    }
}
