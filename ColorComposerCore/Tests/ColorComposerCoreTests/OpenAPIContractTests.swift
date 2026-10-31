import Foundation
import XCTest
@testable import ColorComposerCore

/// Pins the `/api/v1` wire contract that `PaletteAPIClient` consumes to the
/// OpenAPI document published by the `color_matching` server
/// (viamin/color_matching#113, served at `GET /api/v1/openapi.json`).
///
/// The committed snapshot lives at `Fixtures/openapi/v1/openapi.json` and
/// covers exactly the endpoints the app uses. When the app migrates to the
/// OpenAPI-generated typed client, these tests are the behavioral contract the
/// migration must keep satisfying: same paths, same query parameter, same
/// envelope keys, same bearer authentication, and a decoder that accepts every
/// payload the spec guarantees (required fields present, optional fields
/// absent).
///
/// Refresh the fixture from a running server with:
/// `curl -o Fixtures/openapi/v1/openapi.json http://localhost:4000/api/v1/openapi.json`
/// (see docs/parity-corpus.md).
final class OpenAPIContractTests: XCTestCase {
    private static let specURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/openapi/v1/openapi.json")

    private let printerProfilesPath = "/api/v1/printer_profiles"
    private let colorsPath = "/api/v1/colors"

    // MARK: - Spec document shape

    func testSnapshotIsOpenAPI3DocumentForColorMatchingV1() throws {
        let spec = try loadSpec()

        let version = try XCTUnwrap(spec["openapi"] as? String)
        XCTAssertTrue(version.hasPrefix("3."), "expected OpenAPI 3.x, found \(version)")

        let info = try XCTUnwrap(spec["info"] as? [String: Any])
        XCTAssertEqual(info["title"] as? String, "Color Matching API")
        XCTAssertEqual(info["version"] as? String, "v1")

        XCTAssertNotNil(spec["paths"] as? [String: Any])
        XCTAssertNotNil(componentSchemas(in: spec))
    }

    func testBearerSecuritySchemeIsDeclaredAndApplied() throws {
        let spec = try loadSpec()

        let schemes = try XCTUnwrap(spec["components"] as? [String: Any])["securitySchemes"] as? [String: Any]
        let bearer = try XCTUnwrap(schemes?["bearerAuth"] as? [String: Any],
                                   "bearerAuth security scheme is missing")
        XCTAssertEqual(bearer["type"] as? String, "http")
        XCTAssertEqual(bearer["scheme"] as? String, "bearer")

        for path in [printerProfilesPath, colorsPath] {
            let operation = try getOperation(path, in: spec)
            let security = try XCTUnwrap(operation["security"] as? [[String: Any]],
                                         "\(path): expected bearer security requirement")
            XCTAssertTrue(security.contains { $0["bearerAuth"] != nil },
                          "\(path): security must reference bearerAuth")
        }
    }

    // MARK: - GET /api/v1/printer_profiles

    func testPrinterProfilesOperationContract() throws {
        let spec = try loadSpec()
        let operation = try getOperation(printerProfilesPath, in: spec)

        XCTAssertEqual(operation["summary"] as? String, "List printer profiles")

        let ok = try response(200, of: operation, at: printerProfilesPath)
        let envelope = try resolvedRef(try jsonSchema(of: ok), in: spec)
        XCTAssertEqual(envelope["title"] as? String, "PrinterProfilesResponse")
        XCTAssertEqual(requiredProperties(of: envelope), ["printer_profiles"])

        let profilesArray = try XCTUnwrap(nestedProperty("printer_profiles", of: envelope))
        let profileSchema = try resolvedRef(
            try XCTUnwrap(profilesArray["items"] as? [String: Any]),
            in: spec
        )
        XCTAssertEqual(
            Set(requiredProperties(of: profileSchema)),
            ["id", "printer_make_model", "paper_type", "ink_type"],
            "PrinterProfile required fields changed on the server"
        )

        XCTAssertNotNil(try response(401, of: operation, at: printerProfilesPath),
                        "401 must be documented so the client can map it to .unauthorized")
    }

    // MARK: - GET /api/v1/colors

    func testColorsOperationContract() throws {
        let spec = try loadSpec()
        let operation = try getOperation(colorsPath, in: spec)

        XCTAssertEqual(operation["summary"] as? String, "List palette colors and illuminant responses")

        let parameters = try XCTUnwrap(operation["parameters"] as? [[String: Any]])
        let byName = try XCTUnwrap(Dictionary(uniqueKeysWithValues: parameters.compactMap { p in
            (p["name"] as? String).map { ($0, p) }
        }, uniquingKeysWith: { a, _ in a }))

        let profileID = try XCTUnwrap(byName["printer_profile_id"], "printer_profile_id query parameter is missing")
        XCTAssertEqual(profileID["in"] as? String, "query")
        XCTAssertEqual(profileID["required"] as? Bool, true)
        XCTAssertEqual((profileID["schema"] as? [String: Any])?["type"] as? String, "integer")

        XCTAssertNotNil(byName["palette_id"], "palette_id query parameter is missing")
        XCTAssertEqual(byName["palette_id"]?["required"] as? Bool, false)

        let ok = try response(200, of: operation, at: colorsPath)
        let envelope = try resolvedRef(try jsonSchema(of: ok), in: spec)
        XCTAssertEqual(envelope["title"] as? String, "ColorsResponse")
        XCTAssertEqual(Set(requiredProperties(of: envelope)), ["printer_profile", "colors"])

        XCTAssertNotNil(try response(401, of: operation, at: colorsPath))
        XCTAssertNotNil(try response(404, of: operation, at: colorsPath))
    }

    /// The per-color schema is the sharpest edge of the contract: `rgb` and
    /// `palette_name` are optional, everything else the client decodes is
    /// required. If this set changes on the server, the generated client and
    /// the DTOs must be revisited together.
    func testColorItemRequiredProperties() throws {
        let spec = try loadSpec()
        let colorItem = try colorItemSchema(in: spec)

        XCTAssertEqual(
            Set(requiredProperties(of: colorItem)),
            ["id", "name", "hex", "palette_id", "sort_order", "responses"],
            "ColorsResponse color-item required set changed on the server"
        )

        let properties = try XCTUnwrap(colorItem["properties"] as? [String: Any])
        let rgb = try XCTUnwrap(properties["rgb"] as? [String: Any])
        XCTAssertEqual(rgb["$ref"] as? String, "#/components/schemas/Rgb")

        let rgbSchema = try resolvedRef(rgb, in: spec)
        XCTAssertEqual(Set(requiredProperties(of: rgbSchema)), ["r", "g", "b"])

        let responses = try XCTUnwrap(properties["responses"] as? [String: Any])
        XCTAssertEqual(responses["additionalProperties"] as? Bool, true,
                       "responses must stay an open map keyed by light source")
    }

    // MARK: - Client decoding honors the published contract

    /// A payload carrying exactly the fields the spec guarantees (every
    /// required field present, every optional field absent) must decode
    /// through the client's DTOs and still yield a solver-ready domain color.
    func testClientDecodesMinimalSpecConformantColorsPayload() throws {
        let payload = """
        {
          "printer_profile": {
            "id": 1, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"
          },
          "colors": [
            {
              "id": 9, "name": "Cyan", "hex": "#00FFFF",
              "palette_id": 3, "sort_order": 1,
              "responses": {"red": {"brightness": 0.25}, "lps": {"brightness": 0.125}}
            }
          ]
        }
        """
        let envelope = try decodeEnvelope(payload)

        let dto = try XCTUnwrap(envelope.colors.first)
        XCTAssertNil(dto.rgb, "rgb is optional per the spec; absence must decode")
        XCTAssertNil(dto.paletteName, "palette_name is optional per the spec; absence must decode")
        XCTAssertEqual(dto.id, 9)
        XCTAssertEqual(dto.name, "Cyan")
        XCTAssertEqual(dto.paletteId, 3)
        XCTAssertEqual(dto.sortOrder, 1)
        XCTAssertEqual(dto.responses["red"]?.brightness, 0.25)

        let domain = try XCTUnwrap(dto.toDomain(), "spec-minimal color must convert to the domain model")
        XCTAssertEqual(domain.rgb, RGBColor(hex: "#00FFFF"), "rgb absence must fall back to hex")
        XCTAssertEqual(domain.brightness(for: .lps), 0.125)
        XCTAssertEqual(envelope.printerProfile?.id, 1)
    }

    func testClientDecodesMinimalSpecConformantPrinterProfilesPayload() throws {
        let payload = """
        {"printer_profiles": [{"id": 1, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"}]}
        """
        let decoded = try decode(payload, as: PrinterProfilesResponse.self)
        let profile = try XCTUnwrap(decoded.printerProfiles.first)
        XCTAssertEqual(profile.id, 1)
        XCTAssertEqual(profile.printerMakeModel, "Epson")
    }

    /// Shape finding to preserve across the generated-client migration: the
    /// spec marks `printer_profile` as required in `ColorsResponse`, but the
    /// client deliberately treats it as optional so a server that omits it
    /// still yields servable colors (the offline cache stores it as optional
    /// too). This tolerant decoding is pinned behavior, not an oversight.
    func testClientToleratesOptionalPrinterProfileDespiteSpecRequiringIt() throws {
        let spec = try loadSpec()
        let envelopeSchema = try resolvedRef(
            try jsonSchema(of: try response(200, of: try getOperation(colorsPath, in: spec), at: colorsPath)),
            in: spec
        )
        XCTAssertTrue(requiredProperties(of: envelopeSchema).contains("printer_profile"),
                      "spec snapshot must keep recording printer_profile as required")

        let payload = """
        {"colors": [{"id": 1, "name": "Red", "hex": "#FF0000", "palette_id": 1, "sort_order": 0, "responses": {}}]}
        """
        let envelope = try decodeEnvelope(payload)
        XCTAssertNil(envelope.printerProfile)
        XCTAssertEqual(envelope.colors.count, 1)
    }

    // MARK: - Fixture accessors

    private func loadSpec(file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: Self.specURL)
        } catch {
            XCTFail("OpenAPI snapshot fixture is missing or unreadable at \(Self.specURL.path): \(error)",
                    file: file, line: line)
            throw error
        }
        let raw = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(raw as? [String: Any], "spec snapshot must be a JSON object")
    }

    private func getOperation(_ path: String, in spec: [String: Any]) throws -> [String: Any] {
        let pathItem = try XCTUnwrap((spec["paths"] as? [String: Any])?[path], "path \(path) is missing from the spec")
        return try XCTUnwrap(pathItem["get"] as? [String: Any], "\(path) must support GET")
    }

    private func response(_ statusCode: Int, of operation: [String: Any], at path: String) throws -> [String: Any] {
        let responses = try XCTUnwrap(operation["responses"] as? [String: Any])
        return try XCTUnwrap(responses[String(statusCode)] as? [String: Any],
                             "\(path): response \(statusCode) is not documented")
    }

    private func resolvedRef(_ schema: [String: Any], in spec: [String: Any]) throws -> [String: Any] {
        let reference = try XCTUnwrap(schema["$ref"] as? String)
        XCTAssertTrue(reference.hasPrefix("#/components/schemas/"),
                      "only component schema refs are supported, found \(reference)")
        let name = String(reference.dropFirst("#/components/schemas/".count))
        return try XCTUnwrap(componentSchemas(in: spec)?[name], "unresolvable schema ref \(reference)")
    }

    /// Digs the JSON schema out of a response object's
    /// `content["application/json"].schema`.
    private func jsonSchema(of response: [String: Any]) throws -> [String: Any] {
        let content = try XCTUnwrap(response["content"] as? [String: Any])
        let media = try XCTUnwrap(content["application/json"] as? [String: Any])
        return try XCTUnwrap(media["schema"] as? [String: Any])
    }

    private func componentSchemas(in spec: [String: Any]) -> [String: Any]? {
        (spec["components"] as? [String: Any])?["schemas"] as? [String: Any]
    }

    private func nestedProperty(_ key: String, of schema: [String: Any]) -> [String: Any]? {
        (schema["properties"] as? [String: Any])?[key] as? [String: Any]
    }

    private func requiredProperties(of schema: [String: Any]) -> [String] {
        (schema["required"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private func colorItemSchema(in spec: [String: Any]) throws -> [String: Any] {
        let envelopeSchema = try resolvedRef(
            try jsonSchema(of: try response(200, of: try getOperation(colorsPath, in: spec), at: colorsPath)),
            in: spec
        )
        let colors = try XCTUnwrap(nestedProperty("colors", of: envelopeSchema))
        return try XCTUnwrap(colors["items"] as? [String: Any])
    }

    // MARK: - Decoding helpers (mirror PaletteAPIClient's decoder)

    private func decodeEnvelope(_ json: String) throws -> ColorsResponse {
        try decode(json, as: ColorsResponse.self)
    }

    private func decode<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: Data(json.utf8))
    }
}
