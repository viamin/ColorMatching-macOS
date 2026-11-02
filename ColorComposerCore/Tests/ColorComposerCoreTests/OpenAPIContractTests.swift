import Foundation
import XCTest

/// Locks the `/api/v1` contract the app depends on to the OpenAPI document
/// the `color_matching` server publishes (`GET /api/v1/openapi.json`).
///
/// The document is vendored into this repository so the typed client can be
/// generated from it; these assertions keep the vendored copy and the shapes
/// `PaletteAPIClient` decodes in step, so a server-side change cannot slip
/// through unnoticed.
final class OpenAPIContractTests: XCTestCase {
    private var document: OpenAPIDocument!

    override func setUpWithError() throws {
        try super.setUpWithError()
        document = try OpenAPIDocument.load()
    }

    func testVendoredDocumentIsAnOpenAPI3Document() {
        let version = document.version
        XCTAssertNotNil(version, "The OpenAPI document must declare its version.")
        XCTAssertTrue(
            version?.hasPrefix("3.") == true,
            "The OpenAPI document must be an OpenAPI 3 document, got \(version ?? "none")."
        )
    }

    func testDocumentDeclaresTheEndpointsTheClientUses() {
        XCTAssertNotNil(
            document.operation("/api/v1/printer_profiles", "get"),
            "The OpenAPI document must declare GET /api/v1/printer_profiles."
        )
        XCTAssertNotNil(
            document.operation("/api/v1/colors", "get"),
            "The OpenAPI document must declare GET /api/v1/colors."
        )
    }

    func testPrinterProfilesResponseMatchesTheDecodedShape() throws {
        let schema = try XCTUnwrap(
            document.responseSchema(path: "/api/v1/printer_profiles"),
            "The OpenAPI document must describe the printer profiles response."
        )
        XCTAssertTrue(
            document.propertyNames(schema).contains("printer_profiles"),
            "The printer profiles response must expose a `printer_profiles` array."
        )

        let profile = try XCTUnwrap(
            document.itemSchema(of: schema, property: "printer_profiles"),
            "The OpenAPI document must describe a printer profile."
        )
        XCTAssertTrue(
            document.propertyNames(profile).isSuperset(of: ["id", "printer_make_model", "paper_type", "ink_type"]),
            "A printer profile must document id, printer_make_model, paper_type and ink_type."
        )
    }

    func testColorsResponseMatchesTheDecodedShape() throws {
        let schema = try XCTUnwrap(
            document.responseSchema(path: "/api/v1/colors"),
            "The OpenAPI document must describe the colors response."
        )
        XCTAssertTrue(
            document.propertyNames(schema).isSuperset(of: ["printer_profile", "colors"]),
            "The colors response must expose `printer_profile` and `colors`."
        )

        let color = try XCTUnwrap(
            document.itemSchema(of: schema, property: "colors"),
            "The OpenAPI document must describe a palette color."
        )
        XCTAssertTrue(
            document.propertyNames(color).isSuperset(of: ["id", "name", "hex", "responses"]),
            "A palette color must document id, name, hex and responses."
        )
        XCTAssertTrue(
            document.propertyNames(color).isSuperset(of: ["rgb", "palette_id", "sort_order"]),
            "A palette color must document rgb, palette_id and sort_order."
        )
    }

    func testColorsRequestRequiresThePrinterProfileID() {
        let parameter = document.parameters(path: "/api/v1/colors").first {
            ($0["name"] as? String) == "printer_profile_id"
        }
        XCTAssertNotNil(
            parameter,
            "GET /api/v1/colors must document the printer_profile_id query parameter."
        )
        XCTAssertEqual(
            (parameter?["required"] as? Bool) ?? false,
            true,
            "printer_profile_id must be required: the app always sends it."
        )
    }

    func testDocumentDeclaresBearerAuthentication() {
        let declaresBearer = document.securitySchemes.values.contains { value in
            guard let scheme = value as? [String: Any] else { return false }
            return (scheme["type"] as? String) == "http" && (scheme["scheme"] as? String) == "bearer"
        }
        XCTAssertTrue(
            declaresBearer,
            "The OpenAPI document must declare the bearer scheme the client authenticates with."
        )
    }
}
