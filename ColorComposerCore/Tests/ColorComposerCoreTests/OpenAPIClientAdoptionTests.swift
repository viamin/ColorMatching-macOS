import Foundation
import XCTest

/// Structural adoption tests for the generated OpenAPI client (issue #39).
///
/// `PaletteAPIClient` hand-rolls its `/api/v1` requests today. The server now
/// publishes an OpenAPI document (viamin/color_matching#110), and this package
/// is meant to consume it through `swift-openapi-generator` +
/// `swift-openapi-runtime`. These tests fail until the migration lands, and
/// pin the two artifacts the migration must commit:
///
/// - `ColorComposerCore/OpenAPI/openapi.yaml` — the OpenAPI document the
///   client is generated from.
/// - `Package.swift` declaring the generator plugin and runtime library.
///
/// Wire-level behavior that the migration must preserve (endpoints, query
/// parameter, headers, error mapping, envelope decoding) is pinned separately
/// in `PaletteAPIClientTests` and `APIDecodingTests`, and the disk-cache /
/// offline fallback behavior is pinned in `ProfileColorCacheTests`.
///
/// See `docs/solver-parity-corpus.md` for the companion contract on the solver
/// parity corpus.
final class OpenAPIClientAdoptionTests: XCTestCase {
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var openAPIDocumentURL: URL {
        packageRoot.appendingPathComponent("OpenAPI").appendingPathComponent("openapi.yaml")
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func testOpenAPIDocumentIsCommitted() throws {
        let url = Self.openAPIDocumentURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail(
                "OpenAPI document is not committed at \(url.path). Export it from "
                    + "viamin/color_matching#110 and generate the typed client from it "
                    + "(swift-openapi-generator + swift-openapi-runtime)."
            )
            return
        }

        let document = try read(url)
        XCTAssertTrue(
            document.contains("printer_profiles"),
            "The OpenAPI document must describe GET /api/v1/printer_profiles, the endpoint PaletteAPIClient fetches today"
        )
        XCTAssertTrue(
            document.contains("colors"),
            "The OpenAPI document must describe GET /api/v1/colors, the endpoint PaletteAPIClient fetches today"
        )
    }

    func testPackageManifestDeclaresOpenAPIGeneratorAndRuntime() throws {
        let manifest = try read(Self.packageRoot.appendingPathComponent("Package.swift"))

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must declare the swift-openapi-generator plugin so the typed client is generated at build time"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must declare the swift-openapi-runtime library the generated client depends on"
        )
    }
}
