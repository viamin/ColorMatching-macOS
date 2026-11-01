import Foundation
import XCTest

/// Guards the OpenAPI generated-client migration (issue #39; depends on the
/// `/api/v1` OpenAPI document published by viamin/color_matching#110).
///
/// - `ColorComposerCore/openapi.yaml` is the canonical location of the
///   committed document that `swift-openapi-generator` consumes.
///   `testOpenAPIDocumentIsCommittedAtTheCanonicalPath` fails until the
///   document lands there (red phase for the generated-client deliverable).
/// - `api-v1-expected-contract.json` (in `Fixtures/OpenAPI`) snapshots the
///   wire contract `PaletteAPIClient` decodes today (`APIModels.swift`); the
///   snapshot tests pin it so any `/api/v1` shape change found during the
///   migration is detected rather than silently absorbed.
/// - Once the real document is committed, it must cover the same endpoints,
///   query parameter, bearer auth, and snake_case fields — that comparison is
///   the spec-vs-client drift detector.
final class OpenAPIContractTests: XCTestCase {
    private static let canonicalDocumentNames = ["openapi.yaml", "openapi.yml", "openapi.json"]

    /// Every snake_case wire field the client decodes today (APIModels.swift);
    /// the committed spec and the snapshot must both list all of them.
    private static let requiredWireFields: Set<String> = [
        "printer_profiles", "colors", "printer_profile",
        "printer_make_model", "paper_type", "ink_type",
        "hex", "rgb", "palette_id", "palette_name", "sort_order", "responses",
        "brightness", "source", "raw_value", "raw_unit",
        "apparent_brightness", "measured_at", "test_run_id"
    ]

    /// Property key sets that must match the DTO CodingKeys exactly — these
    /// are too generic for whole-document containment checks, so they are
    /// asserted per-schema on the snapshot.
    private static let schemaPropertySets: [String: Set<String>] = [
        "PrinterProfile": ["id", "printer_make_model", "paper_type", "ink_type"],
        "PaletteColor": ["id", "name", "hex", "rgb", "palette_id", "palette_name", "sort_order", "responses"],
        "ColorResponse": ["brightness", "source", "raw_value", "raw_unit", "apparent_brightness", "measured_at", "test_run_id"],
        "ColorsResponse": ["colors", "printer_profile"],
        "PrinterProfilesResponse": ["printer_profiles"],
        "RGB": ["r", "g", "b"]
    ]

    private static var packageRoot: URL {
        let testFileDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return testFileDirectory
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // ColorComposerCore/
    }

    private static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/OpenAPI", isDirectory: true)
    }

    // MARK: - Canonical document presence

    /// The spec from viamin/color_matching#110 must be committed so
    /// swift-openapi-generator can produce the typed client. This is the
    /// red-phase guard for the generated-client deliverable.
    func testOpenAPIDocumentIsCommittedAtTheCanonicalPath() {
        let found = Self.committedDocumentURL()

        XCTAssertNotNil(
            found,
            "Missing OpenAPI document: commit the /api/v1 spec from viamin/color_matching#110 at "
                + "\(Self.packageRoot.path)/openapi.yaml (or .yml/.json). It is the input to the "
                + "generated client (issue #39); see docs/openapi-generated-client.md."
        )
    }

    // MARK: - Committed document coverage

    /// When the document is committed it must cover exactly what
    /// `PaletteAPIClient` consumes: both endpoints, the
    /// `printer_profile_id` query parameter, bearer auth, and every
    /// snake_case wire field the client decodes.
    func testCommittedDocumentCoversTheClientAPIContract() throws {
        let url = try committedDocumentOrSkip()

        if url.pathExtension.lowercased() == "json" {
            let document = try loadJSONDocument(at: url)
            try assertCoversClientContract(document, source: url.lastPathComponent)
        } else {
            try assertYAMLDocumentCoversClientContract(at: url)
        }
    }

    // MARK: - Snapshot (expected contract) pins

    func testSnapshotPinsSchemaPropertySetsExactly() throws {
        let schemas = try schemas(in: try loadSnapshot())

        for (name, expectedProperties) in Self.schemaPropertySets {
            let actual = schemaProperties(schemas, schema: name)
            XCTAssertEqual(
                actual, expectedProperties,
                "\(name).properties drifted from the DTO wire contract (APIModels.swift) — update the snapshot and record the /api/v1 shape change in the migration notes"
            )
        }
    }

    func testSnapshotCoversTheClientAPIContract() throws {
        try assertCoversClientContract(try loadSnapshot(), source: "api-v1-expected-contract.json")
    }

    // MARK: - Coverage assertions (shared by snapshot and committed document)

    private func assertCoversClientContract(
        _ document: [String: Any],
        source: String
    ) throws {
        let paths = try XCTUnwrap(
            document["paths"] as? [String: Any],
            "\(source): no paths object"
        )
        XCTAssertNotNil(paths["/api/v1/printer_profiles"], "\(source): missing GET /api/v1/printer_profiles")
        XCTAssertNotNil(paths["/api/v1/colors"], "\(source): missing GET /api/v1/colors")

        try assertColorsOperationRequiresPrinterProfileID(paths, source: source)
        try assertBearerSecurityScheme(document, source: source)

        let missing = Self.requiredWireFields.subtracting(propertyNames(in: document))
        XCTAssertTrue(
            missing.isEmpty,
            "\(source): spec no longer describes fields the client decodes: \(missing.sorted()) — a /api/v1 shape change; record it in the migration notes"
        )
    }

    private func assertColorsOperationRequiresPrinterProfileID(
        _ paths: [String: Any],
        source: String
    ) throws {
        let colors = try XCTUnwrap(paths["/api/v1/colors"] as? [String: Any], "\(source): /api/v1/colors malformed")
        let get = try XCTUnwrap(colors["get"] as? [String: Any], "\(source): /api/v1/colors has no get operation")
        let parameters = try XCTUnwrap(get["parameters"] as? [[String: Any]], "\(source): /api/v1/colors declares no parameters")

        let matching = parameters.first { ($0["name"] as? String) == "printer_profile_id" }
        XCTAssertNotNil(matching, "\(source): /api/v1/colors lacks the printer_profile_id query parameter")
        XCTAssertEqual(matching?["in"] as? String, "query", "\(source): printer_profile_id must be a query parameter")
        XCTAssertEqual(matching?["required"] as? Bool, true, "\(source): printer_profile_id must be required")
    }

    private func assertBearerSecurityScheme(
        _ document: [String: Any],
        source: String
    ) throws {
        let components = try XCTUnwrap(document["components"] as? [String: Any], "\(source): no components object")
        let schemes = try XCTUnwrap(components["securitySchemes"] as? [String: Any], "\(source): no securitySchemes")

        let hasBearer = schemes.values.contains { scheme in
            guard let scheme = scheme as? [String: Any] else { return false }
            return (scheme["type"] as? String) == "http" && (scheme["scheme"] as? String) == "bearer"
        }
        XCTAssertTrue(hasBearer, "\(source): no http/bearer security scheme — the client sends Bearer tokens")
    }

    /// Minimal YAML support: without a YAML parser dependency, assert the
    /// contract markers textually. Structurally valid JSON documents get the
    /// full check above.
    private func assertYAMLDocumentCoversClientContract(at url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        for marker in ["/api/v1/printer_profiles", "/api/v1/colors", "printer_profile_id", "bearer"] {
            XCTAssertTrue(text.contains(marker), "\(url.lastPathComponent): missing \(marker)")
        }
        for field in Self.requiredWireFields.sorted() {
            XCTAssertTrue(text.contains("\(field):"), "\(url.lastPathComponent): missing field \(field)")
        }
    }

    // MARK: - Loading helpers

    private static func committedDocumentURL() -> URL? {
        Self.canonicalDocumentNames
            .map { Self.packageRoot.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func committedDocumentOrSkip() throws -> URL {
        guard let url = Self.committedDocumentURL() else {
            throw XCTSkip(
                "OpenAPI document not committed yet (enforced by testOpenAPIDocumentIsCommittedAtTheCanonicalPath)"
            )
        }
        return url
    }

    private func loadSnapshot() throws -> [String: Any] {
        try loadJSONDocument(
            at: Self.fixturesDirectory.appendingPathComponent("api-v1-expected-contract.json")
        )
    }

    private func loadJSONDocument(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "\(url.lastPathComponent): not a JSON object"
        )
    }

    private func schemas(in document: [String: Any]) throws -> [String: Any] {
        let components = try XCTUnwrap(document["components"] as? [String: Any])
        return try XCTUnwrap(components["schemas"] as? [String: Any])
    }

    private func schemaProperties(_ schemas: [String: Any], schema: String) -> Set<String> {
        Set(((schemas[schema] as? [String: Any])?["properties"] as? [String: Any])?.keys ?? [])
    }

    /// Recursively collects every key under a `properties` object.
    private func propertyNames(in node: Any) -> Set<String> {
        var found: Set<String> = []
        if let object = node as? [String: Any] {
            if let properties = object["properties"] as? [String: Any] {
                found.formUnion(properties.keys)
            }
            for value in object.values {
                found.formUnion(propertyNames(in: value))
            }
        } else if let array = node as? [Any] {
            for value in array {
                found.formUnion(propertyNames(in: value))
            }
        }
        return found
    }
}
