import Foundation
import XCTest

/// Contract checks between the committed OpenAPI document and the endpoints
/// `PaletteAPIClient` consumes (issue #39).
///
/// `ColorComposerCore/openapi.json` is the committed JSON form of the spec
/// published by `color_matching` (viamin/color_matching#110) — the same
/// document `swift-openapi-generator` runs against. Committing it in-repo
/// keeps the generated client reproducible and gives these tests something to
/// pin: if the server spec renames or reshapes an endpoint this app consumes,
/// these checks fail before a stale client ships.
///
/// The JSON form is used (rather than YAML) so tests can validate the document
/// with Foundation's JSON support. Both forms are valid generator input.
final class OpenAPIContractTests: XCTestCase {
    /// ColorComposerCore package root (`ColorComposerCore/openapi.json`).
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()          // OpenAPIContractTests.swift
        .deletingLastPathComponent()          // ColorComposerCoreTests/
        .deletingLastPathComponent()          // Tests/
    private static let documentURL = packageRoot.appendingPathComponent("openapi.json")

    /// The OpenAPI document from viamin/color_matching#110 must be committed
    /// for client generation and for the drift checks below to run against.
    func testOpenAPIDocumentIsCommitted() throws {
        guard FileManager.default.fileExists(atPath: Self.documentURL.path) else {
            XCTFail(
                "OpenAPI document is missing at \(Self.documentURL.path). Commit the JSON spec "
                    + "published by viamin/color_matching#110 there — see docs/solver-parity-corpus.md."
            )
            return
        }
        _ = try Self.document()
    }

    func testDocumentDeclaresOpenAPI3() throws {
        let document = try skipUnlessSpecCommitted()
        let version = try XCTUnwrap(document["openapi"] as? String)
        XCTAssertTrue(version.hasPrefix("3."), "expected an OpenAPI 3.x document, found \(version)")
    }

    /// Every route `PaletteAPIClient` hits today must exist in the spec as a
    /// GET operation: `printer_profiles` and the `printer_profile_id`-scoped
    /// `colors`. Suffix matching tolerates the `/api/v1` prefix living either
    /// in the path entries or in a `servers` entry.
    func testDocumentExposesEndpointsPaletteAPIClientConsumes() throws {
        let document = try skipUnlessSpecCommitted()
        let paths = try XCTUnwrap(document["paths"] as? [String: Any], "document has no paths object")

        let printerProfiles = try XCTUnwrap(
            Self.pathItem(endingWith: "printer_profiles", in: paths),
            "no GET path ending in printer_profiles — PaletteAPIClient.fetchPrinterProfiles() consumes it"
        )
        XCTAssertNotNil(printerProfiles["get"], "printer_profiles must be a GET operation")

        let colors = try XCTUnwrap(
            Self.pathItem(endingWith: "colors", in: paths),
            "no GET path ending in colors — PaletteAPIClient.fetchColors(printerProfileID:) consumes it"
        )
        XCTAssertNotNil(colors["get"], "colors must be a GET operation")

        let get = try XCTUnwrap(colors["get"] as? [String: Any])
        let parameters = (get["parameters"] as? [[String: Any]]) ?? []
        let hasProfileIDQuery = parameters.contains { parameter in
            parameter["name"] as? String == "printer_profile_id"
                && (parameter["in"] as? String == "query")
        }
        XCTAssertTrue(
            hasProfileIDQuery,
            "the colors GET operation must accept a printer_profile_id query parameter"
        )
    }

    // MARK: - Internals

    private static func document() throws -> [String: Any] {
        let data = try Data(contentsOf: documentURL)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "openapi.json is not a JSON object"
        )
    }

    private static func pathItem(endingWith suffix: String, in paths: [String: Any]) -> [String: Any]? {
        for (path, item) in paths.sorted(by: { $0.key < $1.key }) {
            let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
            if normalized == suffix || normalized.hasSuffix("/" + suffix) {
                return item as? [String: Any]
            }
        }
        return nil
    }
}

private extension XCTestCase {
    /// These drift checks are meaningless until the spec lands (#110): skip
    /// with an issue reference rather than duplicating the committed-document
    /// failure that `testOpenAPIDocumentIsCommitted` already reports.
    func skipUnlessSpecCommitted(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: OpenAPIContractTests.documentURL.path) else {
            throw XCTSkip("OpenAPI document not yet committed (viamin/color_matching#110, tracked in #39)")
        }
        return try OpenAPIContractTests.document()
    }
}
