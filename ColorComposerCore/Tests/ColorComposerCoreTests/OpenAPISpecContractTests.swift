import Foundation
import XCTest

/// Pins the OpenAPI document contract for the generated `PaletteAPIClient`
/// migration (issue #39, depending on viamin/color_matching#110).
///
/// The spec snapshot is served by the server at `GET /api/v1/openapi.json`
/// (no bearer token required — the route runs outside the `:api_auth`
/// pipeline) and must be committed at `ColorComposerCore/openapi.json` so
/// `swift-openapi-generator` can generate the typed client from it.
/// `OpenAPISpecContractTests` keeps the snapshot honest: it fails when the
/// snapshot is missing or stops describing the endpoints `PaletteAPIClient`
/// consumes. Refresh instructions: `docs/solver-parity-corpus.md`.
final class OpenAPISpecContractTests: XCTestCase {
    private static let snapshotURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/ColorComposerCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // ColorComposerCore (package root)
        .appendingPathComponent("openapi.json")

    private func snapshotDocument(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: Self.snapshotURL.path) else {
            XCTFail(
                "OpenAPI snapshot missing at \(Self.snapshotURL.path). "
                    + "Fetch it from the server (`curl $COLOR_MATCHING_URL/api/v1/openapi.json`) "
                    + "and commit it there — see docs/solver-parity-corpus.md.",
                file: file, line: line
            )
            throw NSError(domain: "OpenAPISpecContract", code: 1)
        }
        let data = try Data(contentsOf: Self.snapshotURL)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "OpenAPI snapshot is not a JSON object",
            file: file, line: line
        )
    }

    private func paths(
        in document: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        try XCTUnwrap(document["paths"] as? [String: Any], "spec has no paths object", file: file, line: line)
    }

    private func getOperation(
        _ path: String,
        in paths: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let item = try XCTUnwrap(paths[path] as? [String: Any], "spec is missing path \(path)", file: file, line: line)
        return try XCTUnwrap(item["get"] as? [String: Any], "path \(path) has no GET operation", file: file, line: line)
    }

    func testSnapshotDescribesAnOpenAPI3Document() throws {
        let document = try snapshotDocument()
        let version = try XCTUnwrap(document["openapi"] as? String, "spec has no openapi version field")
        XCTAssertTrue(version.hasPrefix("3."), "expected an OpenAPI 3.x document, got \(version)")
    }

    /// The two endpoints `PaletteAPIClient` consumes today — the generated
    /// client must keep describing them or generation would silently drop
    /// the calls the app makes.
    func testSnapshotDescribesEndpointsConsumedByPaletteAPIClient() throws {
        let paths = try paths(in: try snapshotDocument())
        XCTAssertNoThrow(try getOperation("/api/v1/printer_profiles", in: paths))
        XCTAssertNoThrow(try getOperation("/api/v1/colors", in: paths))
    }

    func testColorsOperationKeepsThePrinterProfileIDQueryParameter() throws {
        let paths = try paths(in: try snapshotDocument())
        let get = try getOperation("/api/v1/colors", in: paths)
        let parameters = try XCTUnwrap(get["parameters"] as? [[String: Any]], "GET /api/v1/colors has no parameters")
        let names = parameters.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("printer_profile_id"), "GET /api/v1/colors lost printer_profile_id (has \(names))")
        let parameter = try XCTUnwrap(parameters.first { $0["name"] as? String == "printer_profile_id" })
        XCTAssertEqual(parameter["in"] as? String, "query")
        XCTAssertTrue(parameter["required"] as? Bool ?? false, "printer_profile_id must stay required")
    }
}
