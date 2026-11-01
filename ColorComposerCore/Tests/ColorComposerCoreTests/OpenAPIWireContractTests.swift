import Foundation
import XCTest
@testable import ColorComposerCore

/// Pins the `/api/v1` wire contract the generated OpenAPI client must be
/// built against (issue #39).
///
/// `Tests/Fixtures/openapi-v1.json` mirrors the subset of the server's
/// served OpenAPI document (`GET /api/v1/openapi.json`, from
/// viamin/color_matching `lib/color_matching_web/api_spec.ex` +
/// `api_schemas.ex`) that `PaletteAPIClient` consumes. These tests verify
/// that the committed contract keeps describing the two endpoints the app
/// depends on, and that payloads allowed by the contract still decode with
/// the app's DTOs — so migrating `PaletteAPIClient` onto a client generated
/// from this document cannot silently change the wire shapes.
final class OpenAPIWireContractTests: XCTestCase {
    private static let spec: [String: Any] = loadSpec()

    private static func loadSpec() -> [String: Any] {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/openapi-v1.json")
        do {
            let data = try Data(contentsOf: fixtureURL)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                fatalError("OpenAPI fixture must decode to a JSON object")
            }
            return object
        } catch {
            fatalError("Failed to load OpenAPI fixture at \(fixtureURL): \(error)")
        }
    }

    private func path(_ name: String) throws -> [String: Any] {
        let paths = try XCTUnwrap(Self.spec["paths"] as? [String: Any])
        return try XCTUnwrap(paths[name] as? [String: Any], "spec is missing path \(name)")
    }

    private func operation(_ name: String, method: String) throws -> [String: Any] {
        let pathItem = try path(name)
        return try XCTUnwrap(pathItem[method] as? [String: Any], "\(name) is missing \(method.uppercased())")
    }

    private func response(_ operation: [String: Any], status: String) throws -> [String: Any] {
        let responses = try XCTUnwrap(operation["responses"] as? [String: Any])
        return try XCTUnwrap(responses[status] as? [String: Any], "operation is missing \(status) response")
    }

    private func schema(named name: String) throws -> [String: Any] {
        let components = try XCTUnwrap(Self.spec["components"] as? [String: Any])
        let schemas = try XCTUnwrap(components["schemas"] as? [String: Any])
        return try XCTUnwrap(schemas[name] as? [String: Any], "spec is missing schema \(name)")
    }

    private func decode<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Document shape

    func testDocumentIsOpenAPI3WithBearerAuth() throws {
        let version = Self.spec["openapi"] as? String ?? ""
        XCTAssertTrue(version.hasPrefix("3."), "expected OpenAPI 3.x document")
        let components = try XCTUnwrap(Self.spec["components"] as? [String: Any])
        let schemes = try XCTUnwrap(components["securitySchemes"] as? [String: Any])
        let bearer = try XCTUnwrap(schemes["bearerAuth"] as? [String: Any])
        XCTAssertEqual(bearer["type"] as? String, "http")
        XCTAssertEqual(bearer["scheme"] as? String, "bearer")
    }

    func testPrinterProfilesOperationMatchesWhatTheAppConsumes() throws {
        let get = try operation("/api/v1/printer_profiles", method: "get")
        let security = try XCTUnwrap(get["security"] as? [[String: Any]])
        XCTAssertEqual(security.first?.keys.first, "bearerAuth")

        let ok = try response(get, status: "200")
        let content = try XCTUnwrap(ok["content"] as? [String: Any])
        let json = try XCTUnwrap(content["application/json"] as? [String: Any])
        XCTAssertEqual(
            (json["schema"] as? [String: Any])?["$ref"] as? String,
            "#/components/schemas/PrinterProfilesResponse"
        )

        XCTAssertNotNil(try response(get, status: "401")["content"], "401 is documented so the client can map it to re-authentication")
    }

    func testColorsOperationRequiresPrinterProfileIDQueryParameter() throws {
        let get = try operation("/api/v1/colors", method: "get")
        let parameters = try XCTUnwrap(get["parameters"] as? [[String: Any]])

        let profileID = try XCTUnwrap(
            parameters.first { ($0["name"] as? String) == "printer_profile_id" },
            "GET /colors must document the printer_profile_id query parameter"
        )
        XCTAssertEqual(profileID["in"] as? String, "query")
        XCTAssertEqual(profileID["required"] as? Bool, true)

        let ok = try response(get, status: "200")
        let content = try XCTUnwrap(ok["content"] as? [String: Any])
        let json = try XCTUnwrap(content["application/json"] as? [String: Any])
        XCTAssertEqual(
            (json["schema"] as? [String: Any])?["$ref"] as? String,
            "#/components/schemas/ColorsResponse"
        )
    }

    // MARK: - Schema required-ness (drift in either direction must fail)

    func testPrinterProfileSchemaRequiresAllFourFields() throws {
        let schema = try schema(named: "PrinterProfile")
        let required = try XCTUnwrap(schema["required"] as? [String])
        XCTAssertEqual(Set(required), ["id", "printer_make_model", "paper_type", "ink_type"])
    }

    func testColorsResponseSchemaRequiredFields() throws {
        let envelope = try schema(named: "ColorsResponse")
        XCTAssertEqual(
            Set(try XCTUnwrap(envelope["required"] as? [String])),
            ["printer_profile", "colors"],
            "the server always returns the profile alongside the colors"
        )

        let colors = try XCTUnwrap(envelope["properties"] as? [String: Any])["colors"] as? [String: Any]
        let items = try XCTUnwrap(colors?["items"] as? [String: Any])
        XCTAssertEqual(
            Set(try XCTUnwrap(items["required"] as? [String])),
            ["id", "name", "hex", "palette_id", "sort_order", "responses"]
        )

        let properties = try XCTUnwrap(items["properties"] as? [String: Any])
        let paletteName = try XCTUnwrap(properties["palette_name"] as? [String: Any])
        XCTAssertEqual(paletteName["nullable"] as? Bool, true, "palette_name is the one documented nullable field")
    }

    // MARK: - Spec-conforming payloads decode with the app's DTOs

    func testMinimalSpecConformingColorsPayloadDecodes() throws {
        // Only fields the schema marks required (rgb, palette_name omitted).
        let json = """
        {
          "printer_profile": {"id": 3, "printer_make_model": "Canon", "paper_type": "Glossy", "ink_type": "Pigment"},
          "colors": [
            {
              "id": 9, "name": "Sodium Lemon", "hex": "#F5E050",
              "palette_id": 2, "sort_order": 0,
              "responses": {"lps": {"brightness": 0.875, "source": "response"}}
            }
          ]
        }
        """
        let envelope = try decode(json, as: ColorsResponse.self)
        XCTAssertEqual(envelope.printerProfile?.id, 3)
        XCTAssertEqual(envelope.colors.count, 1)

        let dto = try XCTUnwrap(envelope.colors.first)
        XCTAssertNil(dto.rgb, "rgb is optional on the wire; the domain falls back to hex")
        XCTAssertNil(dto.paletteName, "palette_name is nullable")
        XCTAssertEqual(dto.responses["lps"]?.brightness, 0.875)

        let domain = try XCTUnwrap(dto.toDomain())
        XCTAssertEqual(domain.rgb, RGBColor(hex: "#F5E050"))
        XCTAssertEqual(domain.brightness(for: .lps), 0.875)
    }

    func testSpecConformingProfilePayloadDecodesAndAppToleratesNulls() throws {
        // The schema requires all four fields; the app additionally tolerates
        // JSON nulls so older/edge servers cannot crash decoding.
        let required = """
        {"printer_profiles":[{"id":1,"printer_make_model":"Epson","paper_type":"Matte","ink_type":"Dye"}]}
        """
        let withNulls = """
        {"printer_profiles":[{"id":2,"printer_make_model":null,"paper_type":null,"ink_type":null}]}
        """
        XCTAssertEqual(try decode(required, as: PrinterProfilesResponse.self).printerProfiles.first?.id, 1)
        XCTAssertEqual(try decode(withNulls, as: PrinterProfilesResponse.self).printerProfiles.first?.displayName, "Profile #2")
    }
}
