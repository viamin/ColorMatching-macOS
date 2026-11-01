import Foundation
import XCTest

/// Structural tests for the generated OpenAPI client adoption (issue #39).
///
/// `PaletteAPIClient` hand-rolls its `/api/v1` requests today. The server
/// now publishes an OpenAPI 3 contract (viamin/color_matching#110), and this
/// package must consume it: `swift-openapi-generator` (SwiftPM plugin)
/// generates the typed client at build time from a committed OpenAPI
/// document, backed by the `swift-openapi-runtime` package, while
/// `PaletteAPIClient` keeps its public surface and its disk-cache /
/// offline-stale behavior by wrapping the generated client.
///
/// The generated sources themselves are build-time artifacts and are never
/// committed, so what *is* inspectable — and what these tests pin — is the
/// package-manifest wiring and the committed document plus the endpoint
/// surface it must describe. They fail until the migration lands.
final class GeneratedOpenAPIClientTests: XCTestCase {
    /// The generator plugin requires the document at exactly
    /// `<target sources>/OpenAPI/openapi.{yaml,yml,json}`.
    private static let documentCandidates = [
        "OpenAPI/openapi.yaml",
        "OpenAPI/openapi.yml",
        "OpenAPI/openapi.json"
    ]

    // MARK: - Package manifest wiring

    /// The package must depend on the runtime and apply the generator plugin
    /// to `ColorComposerCore`.
    func testPackageManifestDeclaresOpenAPIStack() throws {
        let manifest = try String(
            contentsOf: packageDirectory().appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "ColorComposerCore/Package.swift must depend on swift-openapi-runtime"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "ColorComposerCore/Package.swift must reference the swift-openapi-generator package for the plugin"
        )
        XCTAssertTrue(
            manifest.contains("OpenAPIGenerator"),
            "the ColorComposerCore target must apply the OpenAPIGenerator plugin"
        )
    }

    // MARK: - Committed OpenAPI document

    /// The OpenAPI document must be committed at the layout the generator
    /// plugin reads, so `swift build` reproduces the client without network
    /// access or manual steps.
    func testOpenAPIDocumentIsCommittedAtGeneratorLayout() throws {
        XCTAssertNotNil(
            committedDocumentURL(),
            "no OpenAPI document found under Sources/ColorComposerCore/OpenAPI/; "
                + "commit the server's published spec as openapi.yaml|yml|json there "
                + "(swift-openapi-generator reads exactly that path)"
        )
    }

    /// The document must describe the `/api/v1` surface `PaletteAPIClient`
    /// consumes today — the two GET endpoints and the bearer scheme the
    /// client sends tokens with. Anything less and the migration would drop
    /// live behavior.
    func testOpenAPIDocumentCoversPaletteClientEndpoints() throws {
        let document = try XCTUnwrap(
            committedDocumentURL(),
            "OpenAPI document not committed yet; testOpenAPIDocumentIsCommittedAtGeneratorLayout describes where it belongs"
        )
        let text = try String(contentsOf: document, encoding: .utf8)

        if document.pathExtension == "json" {
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                "OpenAPI document is not a JSON object"
            )
            let paths = try XCTUnwrap(object["paths"] as? [String: Any], "document has no paths")
            let profiles = try XCTUnwrap(paths["/api/v1/printer_profiles"] as? [String: Any])
            XCTAssertNotNil(profiles["get"], "/api/v1/printer_profiles must declare GET")
            let colors = try XCTUnwrap(paths["/api/v1/colors"] as? [String: Any])
            XCTAssertNotNil(colors["get"], "/api/v1/colors must declare GET")

            let components = try XCTUnwrap(object["components"] as? [String: Any])
            let schemes = try XCTUnwrap(components["securitySchemes"] as? [String: Any])
            XCTAssertNotNil(schemes["bearerAuth"], "document must declare the bearerAuth scheme")
        } else {
            XCTAssertTrue(text.contains("/api/v1/printer_profiles"), "document must describe GET /api/v1/printer_profiles")
            XCTAssertTrue(text.contains("/api/v1/colors"), "document must describe GET /api/v1/colors")
            XCTAssertTrue(text.contains("bearerAuth"), "document must declare the bearerAuth scheme")
        }
    }

    // MARK: - Location plumbing

    /// The `ColorComposerCore` package directory, found by walking up from
    /// this test file until a directory containing `ColorComposerCore/`
    /// appears — the package may be checked out standalone or inside the app
    /// repository.
    private func packageDirectory() -> URL {
        let testFile = URL(fileURLWithPath: #filePath)
        var directory = testFile.deletingLastPathComponent()
        while directory.pathComponents.count > 1 {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("ColorComposerCore/Package.swift").path
            ) {
                return directory.appendingPathComponent("ColorComposerCore", isDirectory: true)
            }
            directory.deleteLastPathComponent()
        }
        XCTFail("could not locate the repository root from \(testFile.path)")
        return testFile
    }

    private func committedDocumentURL() -> URL? {
        let sources = packageDirectory()
            .appendingPathComponent("Sources/ColorComposerCore", isDirectory: true)
        for candidate in Self.documentCandidates
        where FileManager.default.fileExists(atPath: sources.appendingPathComponent(candidate).path) {
            return sources.appendingPathComponent(candidate)
        }
        return nil
    }
}
