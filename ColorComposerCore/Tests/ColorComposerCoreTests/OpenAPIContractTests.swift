import Foundation
import XCTest

/// Contract probes for the generated-OpenAPI-client adoption (issue #39).
///
/// These tests pin the artifacts the migration must put in place once the
/// server publishes its OpenAPI spec (viamin/color_matching#110):
///
/// 1. the OpenAPI document is committed inside the `ColorComposerCore`
///    package (canonical path: `Sources/ColorComposerCore/OpenAPI/openapi.yaml`),
/// 2. the document describes both `/api/v1` operations `PaletteAPIClient`
///    consumes today — `GET /api/v1/printer_profiles` and
///    `GET /api/v1/colors` — so the generated client covers the app's needs,
/// 3. `Package.swift` declares `swift-openapi-generator` and
///    `swift-openapi-runtime` and applies the `OpenAPIGenerator` plugin.
///
/// Until the spec is vendored these probes fail by design (red phase); see
/// `docs/openapi-adoption.md` for the full migration contract.
final class OpenAPIContractTests: XCTestCase {
    // MARK: - Locations

    /// `.../ColorComposerCore/Tests/ColorComposerCoreTests/OpenAPIContractTests.swift`
    /// → `.../ColorComposerCore`.
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Candidate document locations, in preference order. The first is the
    /// `swift-openapi-generator` SwiftPM plugin default; the others accept a
    /// repo-named document without churn.
    private static var openAPIDocumentCandidates: [URL] {
        let root = packageRoot
        return [
            root.appendingPathComponent("Sources/ColorComposerCore/OpenAPI/openapi.yaml"),
            root.appendingPathComponent("Sources/ColorComposerCore/OpenAPI/openapi.yml"),
            root.appendingPathComponent("Sources/ColorComposerCore/OpenAPI/color_matching.yaml"),
            root.appendingPathComponent("OpenAPI/openapi.yaml"),
            root.appendingPathComponent("OpenAPI/color_matching.yaml")
        ]
    }

    private static func committedOpenAPIDocument() -> URL? {
        openAPIDocumentCandidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - The OpenAPI document

    func testOpenAPIDocumentIsCommittedToThePackage() throws {
        guard let documentURL = Self.committedOpenAPIDocument() else {
            let expected = Self.openAPIDocumentCandidates.first?.path ?? ""
            return XCTFail(
                "no OpenAPI document found — commit the spec published by viamin/color_matching#110 " +
                    "at \(expected) (or another documented candidate path)"
            )
        }
        let contents = try Self.read(documentURL)
        XCTAssertFalse(
            contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "OpenAPI document at \(documentURL.path) is empty"
        )
    }

    func testOpenAPIDocumentDescribesBothConsumedOperations() throws {
        guard let documentURL = Self.committedOpenAPIDocument() else {
            return XCTFail(
                "no OpenAPI document found — commit the spec published by viamin/color_matching#110 " +
                    "before asserting its operations"
            )
        }
        let document = try Self.read(documentURL)

        for path in ["/api/v1/printer_profiles", "/api/v1/colors"] {
            XCTAssertTrue(
                document.contains(path),
                "\(documentURL.lastPathComponent) must describe \(path); it is consumed by PaletteAPIClient"
            )
        }
        let declaresGetOperations = document.contains("get:") || document.contains("\"get\"")
        XCTAssertTrue(
            declaresGetOperations,
            "\(documentURL.lastPathComponent) must declare GET operations for the consumed /api/v1 endpoints"
        )
    }

    // MARK: - Package manifest adoption

    func testPackageManifestDeclaresOpenAPIGeneratorAndRuntime() throws {
        let manifest = try Self.read(Self.packageRoot.appendingPathComponent("Package.swift"))

        XCTAssertTrue(
            manifest.contains("swift-openapi-generator"),
            "Package.swift must depend on swift-openapi-generator (apple/swift-openapi-generator) " +
                "to generate the typed /api/v1 client"
        )
        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "Package.swift must depend on swift-openapi-runtime; the generated client links it"
        )
        XCTAssertTrue(
            manifest.contains("OpenAPIGenerator"),
            "Package.swift must apply the OpenAPIGenerator plugin to the ColorComposerCore target"
        )
    }
}
