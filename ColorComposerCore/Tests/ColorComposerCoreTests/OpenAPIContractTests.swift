import Foundation
import XCTest

/// Contract tests for the generated OpenAPI client migration (issue #39).
///
/// These pin the artifacts the migration must add before `PaletteAPIClient`
/// can be regenerated/wrapped from a typed client:
///
/// - the OpenAPI document, committed at the `swift-openapi-generator`
///   build-plugin default location
///   `ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.yaml`, and
///   describing both `/api/v1` operations the app consumes;
/// - `ColorComposerCore/Package.swift` declaring the `swift-openapi-generator`
///   and `swift-openapi-runtime` package dependencies.
///
/// They fail (red) until the migration lands — by design in the test-first
/// phase — and then guard the artifacts against silent removal. See
/// `docs/openapi-client.md` for the migration plan and behavior-preservation
/// notes.
final class OpenAPIContractTests: XCTestCase {
    private static let openAPIRelativePath = "ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.yaml"

    func testOpenAPIDocumentIsCommittedAtGeneratorDefaultPath() throws {
        let document = try repoRoot().appendingPathComponent(Self.openAPIRelativePath)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: document.path),
            "OpenAPI document missing at \(document.path) — the swift-openapi-generator default location. "
                + "Commit the spec published by viamin/color_matching#110 there (see docs/openapi-client.md)."
        )
    }

    func testOpenAPIDocumentDescribesBothConsumedAPIV1Operations() throws {
        let document = try repoRoot().appendingPathComponent(Self.openAPIRelativePath)
        let spec = try String(contentsOf: document, encoding: .utf8)

        XCTAssertTrue(spec.contains("openapi:"), "The OpenAPI document must declare its version with an `openapi:` key")
        XCTAssertTrue(
            spec.contains("/api/v1/printer_profiles"),
            "The OpenAPI document must describe GET /api/v1/printer_profiles — the profile list the app consumes"
        )
        XCTAssertTrue(
            spec.contains("/api/v1/colors"),
            "The OpenAPI document must describe GET /api/v1/colors — the per-profile color list the app consumes"
        )
    }

    func testPackageDeclaresOpenAPIGeneratorAndRuntimeDependencies() throws {
        let manifest = try String(
            contentsOf: try repoRoot().appendingPathComponent("ColorComposerCore/Package.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "ColorComposerCore/Package.swift must declare the swift-openapi-generator package dependency"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "ColorComposerCore/Package.swift must declare the swift-openapi-runtime package dependency"
        )
    }

    /// Walks up from this test file to the first directory holding both
    /// `ColorComposerCore/Package.swift` and `project.yml` — the repository
    /// root, independent of build layout, symlinks, or working directory.
    private func repoRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()

        while directory.path != "/" {
            let markers = ["ColorComposerCore/Package.swift", "project.yml"]
            if markers.allSatisfy({ FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw NSError(
            domain: "OpenAPIContractTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Repository root not found above #filePath"]
        )
    }
}
