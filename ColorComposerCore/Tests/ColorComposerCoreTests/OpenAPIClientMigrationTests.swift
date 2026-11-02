import Foundation
import XCTest

/// Guards for the generated OpenAPI-client adoption (issue #39).
///
/// These tests intentionally fail until the migration lands: they pin where
/// the OpenAPI document is vendored and that the package declares the
/// `swift-openapi-generator` / `swift-openapi-runtime` toolchain, so the
/// generated client is reproducible from a committed spec rather than
/// hand-maintained DTOs. See `docs/solver-parity-corpus.md` for the intended
/// layout and refresh workflow.
final class OpenAPIClientMigrationTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)      // …/Tests/ColorComposerCoreTests/OpenAPIClientMigrationTests.swift
            .deletingLastPathComponent()     // …/Tests/ColorComposerCoreTests
            .deletingLastPathComponent()     // …/Tests
            .deletingLastPathComponent()     // …/ColorComposerCore
    }

    /// The OpenAPI document must be vendored inside the package so
    /// `swift-openapi-generator` can regenerate the typed client offline.
    func testOpenAPIDocumentIsVendoredForGeneration() throws {
        let candidates = [
            "Sources/ColorComposerCore/OpenAPI.yaml",
            "Sources/ColorComposerCore/OpenAPI/openapi.yaml",
            "Sources/ColorComposerCore/OpenAPI/openapi.json",
            "Sources/ColorComposerCore/openapi.yaml",
            "OpenAPI.yaml",
            "openapi.yaml"
        ]
        let documentURL = candidates
            .map { packageRoot.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }

        let url = try XCTUnwrap(
            documentURL,
            "no vendored OpenAPI document found; expected one of: \(candidates.map { "ColorComposerCore/\($0)" })"
        )

        let document = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(document.contains("/api/v1/printer_profiles"), "spec must describe GET /api/v1/printer_profiles")
        XCTAssertTrue(document.contains("/api/v1/colors"), "spec must describe GET /api/v1/colors")
        XCTAssertTrue(
            document.contains("bearerAuth") || document.contains("scheme: bearer") || document.contains("\"bearer\""),
            "spec must declare the bearer auth scheme the app's tokens use"
        )
    }

    /// The package manifest must wire the OpenAPI generator plugin and the
    /// runtime the generated code imports.
    func testPackageManifestDeclaresOpenAPIGeneratorAndRuntime() throws {
        let manifest = try String(
            contentsOf: packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must depend on swift-openapi-generator (the OpenAPIGenerator plugin)"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must link swift-openapi-runtime for the generated client"
        )
    }
}
