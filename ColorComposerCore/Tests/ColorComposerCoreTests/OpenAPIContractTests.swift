import Foundation
import XCTest

/// Contract pins for the generated OpenAPI client adoption (issue #39).
///
/// Two adoption guards (red until the implementation lands):
/// 1. an OpenAPI document for `color_matching` /api/v1 is committed at the
///    pinned location `ColorComposerCore/Sources/ColorComposerCore/OpenAPI/openapi.json`,
/// 2. `ColorComposerCore/Package.swift` wires up `swift-openapi-generator`
///    (build plugin) and `swift-openapi-runtime`.
///
/// The remaining tests pin the `/api/v1` surface the generated client must
/// keep serving — the versioned palette endpoints `PaletteAPIClient` consumes
/// today — so any spec-driven shape change is caught here rather than in the
/// app. See `docs/openapi-client-adoption.md` for the adoption plan.
///
/// The document is pinned to **JSON** deliberately: the tests parse it with
/// `JSONSerialization` so no YAML dependency is required. `swift-openapi-generator`
/// accepts JSON documents.
final class OpenAPIContractTests: XCTestCase {
    // MARK: - Repository layout

    /// Resolves symlinks so the paths hold both inside the real package and
    /// inside the symlinked harness `bin/lint` builds on Linux hosts.
    private enum Repo {
        static var testsDirectory: URL {
            URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
        }

        static var packageRoot: URL {
            testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        }

        static var openAPIDocumentURL: URL {
            packageRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("ColorComposerCore", isDirectory: true)
                .appendingPathComponent("OpenAPI", isDirectory: true)
                .appendingPathComponent("openapi.json")
        }

        static var packageManifestURL: URL {
            packageRoot.appendingPathComponent("Package.swift")
        }
    }

    private func loadSpecObject() throws -> [String: Any] {
        let url = Repo.openAPIDocumentURL
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "The OpenAPI document at \(url.path) must be a JSON object"
        )
    }

    // MARK: - Adoption guards (red until the generated-client work lands)

    func testOpenAPIDocumentIsCommittedAtPinnedLocation() {
        let url = Repo.openAPIDocumentURL

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "Missing \(url.path). Issue #39 commits the /api/v1 OpenAPI document there (JSON, not YAML — see docs/openapi-client-adoption.md)."
        )
    }

    func testPackageManifestDeclaresOpenAPIToolchain() throws {
        let manifest = try String(contentsOf: Repo.packageManifestURL, encoding: .utf8)

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "ColorComposerCore/Package.swift must declare the swift-openapi-generator package (provides the OpenAPIGenerator build plugin)"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "ColorComposerCore/Package.swift must declare the swift-openapi-runtime dependency"
        )
        XCTAssertTrue(
            manifest.contains("OpenAPIGenerator"),
            "ColorComposerCore/Package.swift must attach the OpenAPIGenerator plugin to the ColorComposerCore target"
        )
    }

    // MARK: - /api/v1 surface pins (active once the document exists)

    func testSpecDescribesPaletteEndpointsUnderApiV1() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Repo.openAPIDocumentURL.path),
            "OpenAPI document not committed yet — adoption guard above is the red marker"
        )

        let spec = try loadSpecObject()
        let openAPIVersion = try XCTUnwrap(spec["openapi"] as? String)
        XCTAssertTrue(openAPIVersion.hasPrefix("3"), "Expected an OpenAPI 3.x document, found \(openAPIVersion)")

        let info = try XCTUnwrap(spec["info"] as? [String: Any])
        XCTAssertFalse(
            (info["version"] as? String ?? "").isEmpty,
            "info.version must be present so client regeneration is traceable"
        )

        let paths = try XCTUnwrap(spec["paths"] as? [String: Any])
        let printerProfiles = try XCTUnwrap(
            (paths["/api/v1/printer_profiles"] as? [String: Any])?["get"] as? [String: Any],
            "The spec must describe GET /api/v1/printer_profiles — the endpoint PaletteAPIClient uses for the profile picker"
        )
        XCTAssertNotNil(printerProfiles["responses"], "GET /api/v1/printer_profiles must declare responses")
        XCTAssertNotNil(printerProfiles["operationId"], "Generated-client method names derive from operationId; it must be present")

        let colors = try XCTUnwrap(
            (paths["/api/v1/colors"] as? [String: Any])?["get"] as? [String: Any],
            "The spec must describe GET /api/v1/colors — the endpoint PaletteAPIClient uses to load a profile's palette"
        )
        XCTAssertNotNil(colors["responses"], "GET /api/v1/colors must declare responses")
        XCTAssertNotNil(colors["operationId"], "Generated-client method names derive from operationId; it must be present")
    }

    func testSpecColorsOperationRequiresPrinterProfileIDQueryParameter() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Repo.openAPIDocumentURL.path),
            "OpenAPI document not committed yet — adoption guard above is the red marker"
        )

        let spec = try loadSpecObject()
        let paths = try XCTUnwrap(spec["paths"] as? [String: Any])
        let colorsGet = try XCTUnwrap(
            (paths["/api/v1/colors"] as? [String: Any])?["get"] as? [String: Any]
        )
        let parameters = try XCTUnwrap(
            colorsGet["parameters"] as? [[String: Any]],
            "GET /api/v1/colors must declare its printer_profile_id query parameter"
        )
        let profileParameter = try XCTUnwrap(
            parameters.first { ($0["name"] as? String) == "printer_profile_id" },
            "GET /api/v1/colors must declare a printer_profile_id parameter"
        )

        XCTAssertEqual(profileParameter["in"] as? String, "query")
        XCTAssertEqual(profileParameter["required"] as? Bool, true)
    }
}
