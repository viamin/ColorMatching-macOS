import Foundation
import XCTest
@testable import ColorComposerCore

/// Enforces the committed OpenAPI document (`Fixtures/openapi-v1.json`,
/// extracted from the `color_matching` service spec served at
/// `GET /api/v1/openapi.json`) as the machine-checked contract for the routes
/// and response shapes `PaletteAPIClient` consumes.
///
/// The schema-driven payload synthesis below is the drift detector: when the
/// server spec adds a `required` field the app's decoding models do not carry,
/// decoding a spec-derived payload fails here — the same failure a generated
/// client migration would surface, caught before the server ships the change.
///
/// See `docs/openapi-client-migration.md` for provenance and refresh steps.
final class OpenAPIContractTests: XCTestCase {
    private let sampleText = "spec-sample"

    // MARK: - Document metadata

    func testDocumentIsTheServerV1Spec() throws {
        let document = try loadDocument()

        let version = try XCTUnwrap(document["openapi"] as? String)
        XCTAssertTrue(version.hasPrefix("3.0."), "expected an OpenAPI 3.0 document, got \(version)")

        let info = try XCTUnwrap(document["info"] as? [String: Any])
        XCTAssertEqual(info["title"] as? String, "Color Matching API")
        XCTAssertEqual(info["version"] as? String, "v1")

        let schemes = try XCTUnwrap(components(of: document)["securitySchemes"] as? [String: Any])
        let bearer = try XCTUnwrap(schemes["bearerAuth"] as? [String: Any])
        XCTAssertEqual(bearer["type"] as? String, "http")
        XCTAssertEqual(bearer["scheme"] as? String, "bearer")
    }

    // MARK: - Routes the client consumes

    func testPrinterProfilesRouteIsDeclaredAsConsumed() throws {
        let document = try loadDocument()
        let operation = try getOperation("/api/v1/printer_profiles", in: document)

        XCTAssertEqual(operation["operationId"] as? String, "ColorPaletteController.printer_profiles")
        try assertSecuredByBearerAuth(operation, path: "/api/v1/printer_profiles")
        try assertJSONResponseRef(
            operation, status: "200", schema: "PrinterProfilesResponse",
            path: "/api/v1/printer_profiles"
        )
        try assertErrorResponses(
            operation, statuses: ["401"], path: "/api/v1/printer_profiles"
        )
    }

    func testColorsRouteIsDeclaredAsConsumed() throws {
        let document = try loadDocument()
        let operation = try getOperation("/api/v1/colors", in: document)

        XCTAssertEqual(operation["operationId"] as? String, "ColorPaletteController.colors")
        try assertSecuredByBearerAuth(operation, path: "/api/v1/colors")

        let parameter = try XCTUnwrap(
            (operation["parameters"] as? [[String: Any]])?.first { $0["name"] as? String == "printer_profile_id" },
            "/api/v1/colors: printer_profile_id parameter is missing"
        )
        XCTAssertEqual(parameter["in"] as? String, "query")
        XCTAssertEqual(parameter["required"] as? Bool, true)
        let schema = try XCTUnwrap(parameter["schema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "integer")

        try assertJSONResponseRef(
            operation, status: "200", schema: "ColorsResponse",
            path: "/api/v1/colors"
        )
        try assertErrorResponses(
            operation, statuses: ["400", "401", "404", "422"], path: "/api/v1/colors"
        )
    }

    /// The service's canonical profile-scoped colors route (the documented
    /// successor to the query-parameter form the app uses today). Declared here
    /// so a future migration to it is a spec-internal move, not a new contract.
    func testProfileScopedColorsRouteIsDeclared() throws {
        let document = try loadDocument()
        let operation = try getOperation("/api/v1/printer_profiles/{printer_profile_id}/colors", in: document)

        XCTAssertEqual(operation["operationId"] as? String, "ColorPaletteController.profile_colors")

        let parameter = try XCTUnwrap(
            (operation["parameters"] as? [[String: Any]])?.first { $0["name"] as? String == "printer_profile_id" },
            "profile-scoped colors: printer_profile_id path parameter is missing"
        )
        XCTAssertEqual(parameter["in"] as? String, "path")

        try assertJSONResponseRef(
            operation, status: "200", schema: "ProfileColorsResponse",
            path: "/api/v1/printer_profiles/{printer_profile_id}/colors"
        )
    }

    // MARK: - Schema ↔ decoding-model conformance

    /// Decodes a payload synthesized from each schema's `required` properties
    /// only: every field the spec guarantees must be representable by the
    /// client models, with nothing else assumed.
    func testRequiredOnlyPayloadsDecodeThroughClientModels() throws {
        let profiles = try decodeProfileEnvelope(includeOptionalProperties: false)
        XCTAssertEqual(profiles.printerProfiles.count, 1)
        XCTAssertEqual(profiles.printerProfiles.first?.id, 7)

        let colors = try decodeColorsEnvelope(includeOptionalProperties: false)
        XCTAssertEqual(colors.colors.count, 1)
        XCTAssertEqual(colors.printerProfile?.id, 7)

        let color = try XCTUnwrap(colors.colors.first)
        XCTAssertEqual(color.id, 7)
        XCTAssertEqual(color.hex, sampleText)
        XCTAssertEqual(color.name, sampleText)
        XCTAssertEqual(color.paletteId, 7)
        XCTAssertEqual(color.sortOrder, 7)
        XCTAssertNil(color.rgb)
        XCTAssertNil(color.paletteName)
    }

    /// Decodes payloads synthesized from every declared property: optional
    /// fields must round-trip through the same models once present.
    func testFullPayloadsDecodeThroughClientModels() throws {
        let profiles = try decodeProfileEnvelope(includeOptionalProperties: true)
        let profile = try XCTUnwrap(profiles.printerProfiles.first)
        XCTAssertEqual(profile.printerMakeModel, sampleText)
        XCTAssertEqual(profile.paperType, sampleText)
        XCTAssertEqual(profile.inkType, sampleText)

        let colors = try decodeColorsEnvelope(includeOptionalProperties: true)
        let color = try XCTUnwrap(colors.colors.first)
        XCTAssertEqual(color.rgb?.r, 7)
        XCTAssertEqual(color.rgb?.g, 7)
        XCTAssertEqual(color.rgb?.b, 7)
        XCTAssertEqual(color.paletteName, sampleText)
    }

    /// The two response schemas must keep requiring the envelope keys the
    /// client decodes; dropping one is a breaking change the migration must
    /// see.
    func testEnvelopeSchemasRequireEnvelopeKeys() throws {
        let document = try loadDocument()

        let profilesSchema = try schemaNamed("PrinterProfilesResponse", in: document)
        XCTAssertEqual(try requiredProperties(of: profilesSchema), ["printer_profiles"])

        let colorsSchema = try schemaNamed("ColorsResponse", in: document)
        XCTAssertEqual(try requiredProperties(of: colorsSchema), ["printer_profile", "colors"])
    }

    // MARK: - Synthesis + decoding helpers

    private func decodeProfileEnvelope(includeOptionalProperties: Bool) throws -> PrinterProfilesResponse {
        let payload = try synthesizedPayload(forSchemaNamed: "PrinterProfilesResponse", includeOptionalProperties: includeOptionalProperties)
        return try decode(PrinterProfilesResponse.self, from: payload)
    }

    private func decodeColorsEnvelope(includeOptionalProperties: Bool) throws -> ColorsResponse {
        let payload = try synthesizedPayload(forSchemaNamed: "ColorsResponse", includeOptionalProperties: includeOptionalProperties)
        return try decode(ColorsResponse.self, from: payload)
    }

    private func decode<T: Decodable>(_ type: T.Type, from payload: [String: Any]) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: try JSONSerialization.data(withJSONObject: payload))
    }

    private func synthesizedPayload(
        forSchemaNamed name: String,
        includeOptionalProperties: Bool
    ) throws -> [String: Any] {
        let document = try loadDocument()
        let schema = try schemaNamed(name, in: document)
        return try synthesizedObject(from: schema, includeOptionalProperties: includeOptionalProperties, in: document)
    }

    private func synthesizedObject(
        from schema: [String: Any],
        includeOptionalProperties: Bool,
        in document: [String: Any]
    ) throws -> [String: Any] {
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let required = Set(schema["required"] as? [String] ?? [])

        var payload: [String: Any] = [:]
        for (key, rawProperty) in properties {
            let include = required.contains(key) || includeOptionalProperties
            guard include, let propertySchema = rawProperty as? [String: Any] else { continue }
            payload[key] = try synthesizedValue(from: propertySchema, includeOptionalProperties: includeOptionalProperties, in: document)
        }
        return payload
    }

    private func synthesizedValue(
        from schema: [String: Any],
        includeOptionalProperties: Bool,
        in document: [String: Any]
    ) throws -> Any {
        if let ref = schema["$ref"] as? String {
            let prefix = "#/components/schemas/"
            XCTAssertTrue(ref.hasPrefix(prefix), "unsupported $ref \(ref)")
            let name = String(ref.dropFirst(prefix.count))
            return try synthesizedValue(from: try schemaNamed(name, in: document), includeOptionalProperties: includeOptionalProperties, in: document)
        }

        switch schema["type"] as? String {
        case "object":
            return try synthesizedObject(from: schema, includeOptionalProperties: includeOptionalProperties, in: document)
        case "array":
            let items = try XCTUnwrap(schema["items"] as? [String: Any], "array schema without items")
            return [try synthesizedValue(from: items, includeOptionalProperties: includeOptionalProperties, in: document)]
        case "integer":
            return 7
        case "number":
            return 0.5
        case "boolean":
            return true
        case "string":
            return sampleText
        default:
            return [String: Any]()
        }
    }

    // MARK: - Document access helpers

    private func loadDocument() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("openapi-v1.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func components(of document: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(document["components"] as? [String: Any], "components missing")
    }

    private func schemaNamed(_ name: String, in document: [String: Any]) throws -> [String: Any] {
        let schemas = try XCTUnwrap(components(of: document)["schemas"] as? [String: Any], "components.schemas missing")
        return try XCTUnwrap(schemas[name] as? [String: Any], "schema \(name) missing")
    }

    private func getOperation(_ path: String, in document: [String: Any]) throws -> [String: Any] {
        let paths = try XCTUnwrap(document["paths"] as? [String: Any], "paths missing")
        let item = try XCTUnwrap(paths[path] as? [String: Any], "path \(path) is not declared")
        return try XCTUnwrap(item["get"] as? [String: Any], "\(path) declares no GET operation")
    }

    private func requiredProperties(of schema: [String: Any]) throws -> [String] {
        schema["required"] as? [String] ?? []
    }

    // MARK: - Operation assertions

    private func assertSecuredByBearerAuth(_ operation: [String: Any], path: String) throws {
        let security = try XCTUnwrap(operation["security"] as? [[String: Any]], "\(path): no security requirements")
        XCTAssertTrue(
            security.contains { $0["bearerAuth"] != nil },
            "\(path): operation must accept the bearerAuth scheme the client sends"
        )
    }

    private func assertJSONResponseRef(
        _ operation: [String: Any],
        status: String,
        schema: String,
        path: String
    ) throws {
        let responses = try XCTUnwrap(operation["responses"] as? [String: Any], "\(path): no responses")
        let ok = try XCTUnwrap(responses[status] as? [String: Any], "\(path): \(status) response missing")
        let content = try XCTUnwrap(ok["content"] as? [String: Any], "\(path): \(status) has no content")
        let json = try XCTUnwrap(content["application/json"] as? [String: Any], "\(path): \(status) is not application/json")
        let schemaRef = try XCTUnwrap(json["schema"] as? [String: Any], "\(path): \(status) has no schema")
        XCTAssertEqual(schemaRef["$ref"] as? String, "#/components/schemas/\(schema)", "\(path): \(status) schema")
    }

    private func assertErrorResponses(
        _ operation: [String: Any],
        statuses: [String],
        path: String
    ) throws {
        for status in statuses {
            try assertJSONResponseRef(operation, status: status, schema: "ApiErrorResponse", path: path)
        }
    }
}
