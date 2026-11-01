import Foundation
import XCTest

/// Structural checks for the generated-OpenAPI-client deliverable (issue #39).
///
/// These tests are deliberately file-based: they assert that the artifacts the
/// migration must introduce — the committed OpenAPI document, the
/// `swift-openapi-generator`/`swift-openapi-runtime` wiring in `Package.swift`,
/// and the generated client sources — exist where the package layout puts
/// them. They run **red** until the migration lands; the behavioral half of
/// the contract (same URLs, headers, errors, and decoded DTOs) is enforced by
/// `PaletteAPIClientContractTests`, which must stay green across the
/// migration. See `docs/openapi-client-migration.md`.
final class OpenAPIGeneratedClientTests: XCTestCase {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/ColorComposerCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root (ColorComposerCore/)

    func testPackageWiresSwiftOpenAPIGeneratorAndRuntime() throws {
        let manifest = try XCTUnwrap(
            try? String(contentsOf: Self.packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8),
            "Package.swift is unreadable"
        )

        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must depend on swift-openapi-runtime so the generated client can run"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must declare the swift-openapi-generator build plugin that generates the typed client from the OpenAPI document"
        )
    }

    func testOpenAPIDocumentIsCommittedAndDescribesConsumedEndpoints() throws {
        let documentURL = Self.committedOpenAPIDocument
        let path = documentURL?.path
            ?? Self.packageRoot.appendingPathComponent("openapi.yaml").path

        let document = try XCTUnwrap(
            documentURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) },
            """
            No OpenAPI document is committed at \(path). Issue #39 expects the \
            spec published by viamin/color_matching#110 (served at \
            /api/v1/openapi.json) committed into ColorComposerCore so \
            swift-openapi-generator can generate the typed client from it. See \
            docs/openapi-client-migration.md.
            """
        )

        XCTAssertFalse(document.isEmpty, "the committed OpenAPI document must not be empty")
        XCTAssertTrue(document.contains("openapi"), "the document must identify its OpenAPI version")
        XCTAssertTrue(
            document.contains("/api/v1/printer_profiles"),
            "the document must describe GET /api/v1/printer_profiles — the app's profile-list endpoint"
        )
        XCTAssertTrue(
            document.contains("/api/v1/colors"),
            "the document must describe GET /api/v1/colors — the app's per-profile colors endpoint"
        )
    }

    func testGeneratedClientSourcesAreCommitted() throws {
        let generatedDirectory = Self.packageRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("ColorComposerCore", isDirectory: true)
            .appendingPathComponent("OpenAPI", isDirectory: true)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: generatedDirectory.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        XCTAssertTrue(
            exists,
            """
            The generated OpenAPI client sources are missing at \
            \(generatedDirectory.path). Building the package should run the \
            swift-openapi-generator plugin over the committed OpenAPI document \
            and place the generated client under Sources/ColorComposerCore/OpenAPI.
            """
        )
        guard exists else { return }

        let generatedSwiftFiles = (try? FileManager.default.contentsOfDirectory(
            at: generatedDirectory, includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(
            generatedSwiftFiles.isEmpty,
            "the generated OpenAPI client directory exists but holds no Swift sources"
        )
    }

    /// The committed spec, whichever name it uses. `openapi.yaml` is the
    /// swift-openapi-generator convention; `openapi.json` is accepted since
    /// the server publishes JSON.
    private static var committedOpenAPIDocument: URL? {
        ["openapi.yaml", "openapi.json"]
            .map { packageRoot.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
