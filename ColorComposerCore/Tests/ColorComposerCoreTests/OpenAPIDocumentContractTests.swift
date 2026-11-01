import Foundation
import XCTest

/// Pins the OpenAPI document that backs the generated `PaletteAPIClient`
/// transport (issue #39): it must be committed in-repo and must describe the
/// exact `/api/v1` endpoints and snake_case wire keys the client decodes.
/// A failure here means the published spec (viamin/color_matching#110) and
/// this app have drifted — see docs/openapi-client-migration.md.
final class OpenAPIDocumentContractTests: XCTestCase {
    /// `ColorComposerCore/OpenAPI/openapi.json`, resolved from this test file.
    private static let documentURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ColorComposerCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // ColorComposerCore package root
        .appendingPathComponent("OpenAPI")
        .appendingPathComponent("openapi.json")

    func testOpenAPIDocumentIsCommittedAndParses() {
        XCTAssertNotNil(loadDocument())
    }

    func testDocumentDescribesBothConsumedAPIv1Endpoints() throws {
        guard let document = loadDocument() else { return }

        let version = try XCTUnwrap(document["openapi"] as? String, "document must declare an openapi version")
        XCTAssertTrue(version.hasPrefix("3."), "expected an OpenAPI v3 document, found \(version)")

        let paths = try XCTUnwrap(document["paths"] as? [String: Any], "document has no paths object")
        _ = try XCTUnwrap(
            (paths["/api/v1/printer_profiles"] as? [String: Any])?["get"] as? [String: Any],
            "document must describe GET /api/v1/printer_profiles, the endpoint behind fetchPrinterProfiles()"
        )

        let colorsGET = try XCTUnwrap(
            (paths["/api/v1/colors"] as? [String: Any])?["get"] as? [String: Any],
            "document must describe GET /api/v1/colors, the endpoint behind fetchColors(printerProfileID:)"
        )
        let parameters = try XCTUnwrap(
            colorsGET["parameters"] as? [[String: Any]],
            "GET /api/v1/colors must declare its parameters"
        )
        let parameter = try XCTUnwrap(
            parameters.first { ($0["name"] as? String) == "printer_profile_id" },
            "GET /api/v1/colors must take a printer_profile_id parameter"
        )
        XCTAssertEqual(parameter["in"] as? String, "query")
    }

    func testDocumentSchemasMatchTheWireKeysTheClientDecodes() throws {
        guard let document = loadDocument() else { return }

        let components = try XCTUnwrap(document["components"] as? [String: Any], "document has no components object")
        let schemas = try XCTUnwrap(components["schemas"] as? [String: [String: Any]], "document has no component schemas")

        XCTAssertTrue(
            hasSchema(schemas, withArrayProperty: "printer_profiles"),
            "no component schema declares the printer_profiles array envelope key"
        )
        XCTAssertTrue(
            hasSchema(schemas, withProperties: ["colors", "printer_profile"]),
            "no component schema declares the colors/printer_profile envelope keys"
        )
        XCTAssertTrue(
            hasSchema(schemas, withProperties: ["printer_make_model", "paper_type", "ink_type"]),
            "no component schema declares the printer-profile snake_case keys the client decodes"
        )
        XCTAssertTrue(
            hasSchema(schemas, withProperties: ["hex", "responses"]),
            "no component schema declares the palette-color hex/responses keys"
        )
        XCTAssertTrue(
            hasSchema(schemas, withProperty: "brightness"),
            "no component schema declares the measured-response brightness key"
        )
    }

    private func loadDocument() -> [String: Any]? {
        let url = Self.documentURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail(
                "OpenAPI document is missing: commit the spec from viamin/color_matching#110 at " +
                "ColorComposerCore/OpenAPI/openapi.json (see docs/openapi-client-migration.md)"
            )
            return nil
        }
        do {
            return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        } catch {
            XCTFail("OpenAPI document at \(url.path) is not valid JSON: \(error)")
            return nil
        }
    }

    private func hasSchema(
        _ schemas: [String: [String: Any]],
        withProperty property: String
    ) -> Bool {
        hasSchema(schemas, withProperties: [property])
    }

    private func hasSchema(
        _ schemas: [String: [String: Any]],
        withProperties required: [String]
    ) -> Bool {
        schemas.values.contains { schema in
            let properties = schema["properties"] as? [String: Any]
            return required.allSatisfy { properties?[$0] != nil }
        }
    }

    private func hasSchema(
        _ schemas: [String: [String: Any]],
        withArrayProperty property: String
    ) -> Bool {
        schemas.values.contains { schema in
            guard let properties = schema["properties"] as? [String: Any] else { return false }
            return (properties[property] as? [String: Any])?["type"] as? String == "array"
        }
    }
}
