import Foundation
import XCTest

/// Contract tests for the generated OpenAPI client migration (#39).
///
/// These intentionally fail (red) until the implementation run lands the
/// OpenAPI document and the `swift-openapi-generator`/`swift-openapi-runtime`
/// dependencies in `ColorComposerCore`. They pin the conventions the migration
/// must follow so the generated client cannot silently diverge from the
/// behavioral safety net in `PaletteAPIClientContractTests`. The conventions
/// themselves are documented in `docs/openapi-client-contract.md`.
final class OpenAPIClientMigrationTests: XCTestCase {
    // .../ColorComposerCore/Tests/ColorComposerCoreTests/OpenAPIClientMigrationTests.swift
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/ColorComposerCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ColorComposerCore (package root)
    }

    /// Conventional locations for the OpenAPI document the generator plugin
    /// consumes. The first existing one wins; the implementation run commits
    /// the spec (published by viamin/color_matching#110) at one of these.
    private var candidateDocumentURLs: [URL] {
        let names = ["openapi.yaml", "openapi.yml", "openapi.json"]
        let directories = [".", "OpenAPI", "Sources/ColorComposerCore/OpenAPI"]
        return directories.flatMap { directory in
            names.map { name in packageRoot.appendingPathComponent("\(directory)/\(name)") }
        }
    }

    private func locateOpenAPIDocument() -> URL? {
        candidateDocumentURLs.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Dependencies (red until the migration lands)

    func testPackageDeclaresOpenAPIGeneratorAndRuntimeDependencies() throws {
        let manifest = try String(
            contentsOf: packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must depend on swift-openapi-generator (the codegen plugin)"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must depend on swift-openapi-runtime (the generated client's runtime)"
        )
    }

    // MARK: - Document presence (red until the migration lands)

    func testOpenAPIDocumentIsCommitted() {
        let document = locateOpenAPIDocument()
        XCTAssertNotNil(
            document,
            "No OpenAPI document committed under ColorComposerCore (looked in: "
                + candidateDocumentURLs.map(\.path).joined(separator: ", ")
                + "). Commit the /api/v1 spec from viamin/color_matching#110."
        )
    }

    // MARK: - Document shape (red until the migration lands)

    func testOpenAPIDocumentDescribesV1PaletteEndpoints() throws {
        guard let document = locateOpenAPIDocument() else {
            return XCTFail("OpenAPI document not committed yet — see testOpenAPIDocumentIsCommitted")
        }
        let contents = try String(contentsOf: document, encoding: .utf8)
        XCTAssertFalse(contents.isEmpty, "OpenAPI document must not be empty")

        // Works for both YAML and JSON documents: paths and parameter names
        // appear literally in either serialization.
        XCTAssertTrue(
            contents.contains("/api/v1/printer_profiles"),
            "OpenAPI document must describe GET /api/v1/printer_profiles"
        )
        XCTAssertTrue(
            contents.contains("/api/v1/colors"),
            "OpenAPI document must describe GET /api/v1/colors"
        )
        XCTAssertTrue(
            contents.contains("printer_profile_id"),
            "OpenAPI document must declare the printer_profile_id query parameter"
        )
    }
}
