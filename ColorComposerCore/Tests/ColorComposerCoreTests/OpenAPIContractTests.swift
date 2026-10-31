import Foundation
import XCTest
@testable import ColorComposerCore

/// Contract tests for the generated OpenAPI client (issue #39).
///
/// `ColorComposerCore` must commit the server's OpenAPI document and wire
/// `swift-openapi-generator` + `swift-openapi-runtime` into the package, and
/// `PaletteAPIClient` must migrate onto the generated client **without any
/// change to the `/api/v1` wire shapes this app already decodes**. These
/// tests pin all three:
///
/// 1. the document lives at `Sources/ColorComposerCore/OpenAPI/openapi.json`
///    (refreshed verbatim from the server's `GET /api/v1/openapi.json`,
///    viamin/color_matching#110);
/// 2. `Package.swift` wires the generator plugin and runtime library;
/// 3. the document's response schemas agree, property-for-property, with the
///    snake_case payloads `PaletteAPIClient` decodes today — so a server-side
///    `/api/v1` shape change is caught here, not in the app.
///
/// See `docs/generated-openapi-client.md`.
final class OpenAPIContractTests: XCTestCase {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let documentURL = packageRoot
        .appendingPathComponent("Sources/ColorComposerCore/OpenAPI/openapi.json")

    private var document: [String: Any]?

    override func setUpWithError() throws {
        if let data = try? Data(contentsOf: Self.documentURL),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            document = object
        }
    }

    /// Fails with an actionable message when the document is not committed,
    /// so each criterion reports its own failure instead of a shared setUp
    /// error (the Package.swift wiring test below must fail on its own).
    private func requireSpec(file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        try XCTUnwrap(
            document,
            "OpenAPI document is missing or unparseable at \(Self.documentURL.path); commit the server's GET /api/v1/openapi.json there (issue #39, docs/generated-openapi-client.md)",
            file: file, line: line
        )
    }

    // MARK: - Document + wiring presence

    func testDocumentIsAnOpenAPI3Spec() throws {
        let spec = try requireSpec()
        let version = try XCTUnwrap(spec["openapi"] as? String)
        XCTAssertTrue(version.hasPrefix("3."), "expected OpenAPI 3.x, found \(version)")
    }

    func testPackageManifestWiresOpenAPIGeneratorAndRuntime() throws {
        let manifestURL = Self.packageRoot.appendingPathComponent("Package.swift")
        let manifest = try String(decoding: Data(contentsOf: manifestURL), as: UTF8.self)

        XCTAssertTrue(manifest.contains("swift-openapi-runtime"), "Package.swift must depend on swift-openapi-runtime (issue #39)")
        XCTAssertTrue(manifest.contains("OpenAPIGenerator"), "Package.swift must apply the swift-openapi-generator plugin (issue #39)")
    }

    // MARK: - /api/v1 surface

    func testDocumentDescribesBothPaletteEndpointsTheClientUses() throws {
        let spec = try requireSpec()
        let paths = try XCTUnwrap(spec["paths"] as? [String: Any])

        let profiles = try XCTUnwrap(paths["/api/v1/printer_profiles"] as? [String: Any], "spec must describe GET /api/v1/printer_profiles")
        let colors = try XCTUnwrap(paths["/api/v1/colors"] as? [String: Any], "spec must describe GET /api/v1/colors")
        try assertJSONResponse(profiles["get"], operation: "GET /api/v1/printer_profiles", schemaName: "PrinterProfilesResponse")
        try assertJSONResponse(colors["get"], operation: "GET /api/v1/colors", schemaName: "ColorsResponse")
    }

    func testDocumentDeclaresBearerSecurityScheme() throws {
        let spec = try requireSpec()
        let components = try XCTUnwrap(spec["components"] as? [String: Any])
        let schemes = try XCTUnwrap(components["securitySchemes"] as? [String: Any])
        let bearer = try XCTUnwrap(schemes["bearerAuth"] as? [String: Any], "spec must declare the bearerAuth scheme PaletteAPIClient uses")

        XCTAssertEqual(bearer["type"] as? String, "http")
        XCTAssertEqual(bearer["scheme"] as? String, "bearer")
    }

    // MARK: - Spec schemas vs. the wire shapes the app decodes today

    func testProfileSchemaMatchesPrinterProfileDTOWireShape() throws {
        let spec = try requireSpec()
        let schema = try resolveSchema("PrinterProfile", in: spec)
        let properties = schema["properties"] as? [String: Any] ?? [:]

        XCTAssertEqual(schema["type"] as? String, "object")
        for property in ["id", "printer_make_model", "paper_type", "ink_type"] {
            XCTAssertNotNil(properties[property], "PrinterProfile must declare \(property)")
        }
        XCTAssertTrue((schema["required"] as? [String] ?? []).contains("id"), "PrinterProfile.id is required")
    }

    func testColorsSchemaMatchesPaletteColorDTOWireShape() throws {
        let spec = try requireSpec()
        let envelope = try resolveSchema("ColorsResponse", in: spec)
        let colorItem = try colorItemSchema(in: envelope, spec: spec)

        XCTAssertEqual(
            Set(schemaRequired(envelope)),
            ["printer_profile", "colors"],
            "envelope required keys must match what ColorsResponse decodes"
        )
        XCTAssertTrue(
            schemaProperties(colorItem).isSuperset(of: [
                "id", "name", "hex", "rgb", "palette_id", "palette_name", "sort_order", "responses"
            ]),
            "color item must declare every PaletteColorDTO coding key"
        )
        XCTAssertTrue(schemaRequired(colorItem).contains("id"))
        XCTAssertTrue(schemaRequired(colorItem).contains("responses"))
    }

    func testSpecShapedSampleDecodesThroughClientDTOs() throws {
        let spec = try requireSpec()
        let colorItem = try colorItemSchema(in: try resolveSchema("ColorsResponse", in: spec), spec: spec)
        let declared = schemaProperties(colorItem)

        // Build payloads using only property names the spec declares; if a
        // name below ever disappears from the spec, this fails before the
        // decode does.
        for key in ["id", "name", "hex", "rgb", "palette_id", "palette_name", "sort_order", "responses"] {
            XCTAssertTrue(declared.contains(key), "spec no longer declares \(key) on the color item")
        }

        let sample = """
        {
          "printer_profile": {"id": 1, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"},
          "colors": [{
            "id": 123, "name": "Red 12", "hex": "#C64A35",
            "rgb": {"r": 198, "g": 74, "b": 53},
            "palette_id": 5, "palette_name": "Default", "sort_order": 12,
            "responses": {"red": {"brightness": 0.87, "source": "measurement"}}
          }]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope = try decoder.decode(ColorsResponse.self, from: Data(sample.utf8))

        XCTAssertEqual(envelope.printerProfile?.id, 1)
        XCTAssertEqual(envelope.colors.first?.id, 123)
        XCTAssertEqual(envelope.colors.first?.paletteName, "Default")
        XCTAssertEqual(envelope.colors.first?.responses["red"]?.brightness, 0.87)
    }

    // MARK: - JSON digging

    private func assertJSONResponse(
        _ operation: Any?,
        operation name: String,
        schemaName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let get = try XCTUnwrap(operation as? [String: Any], "\(name) operation missing", file: file, line: line)
        let responses = try XCTUnwrap(get["responses"] as? [String: Any], "\(name) responses missing", file: file, line: line)
        let ok = try XCTUnwrap(responses["200"] as? [String: Any], "\(name) 200 response missing", file: file, line: line)
        let content = try XCTUnwrap(ok["content"] as? [String: Any], "\(name) 200 content missing", file: file, line: line)
        let json = try XCTUnwrap(content["application/json"] as? [String: Any], "\(name) must return application/json", file: file, line: line)
        let schemaObject = try XCTUnwrap(json["schema"] as? [String: Any], "\(name) schema missing", file: file, line: line)
        let ref = try XCTUnwrap(schemaObject["$ref"] as? String, "\(name) schema must be a $ref", file: file, line: line)
        XCTAssertTrue(ref.hasSuffix("/\(schemaName)"), "\(name) schema \(ref) must reference \(schemaName)", file: file, line: line)
    }

    private func resolveSchema(
        _ name: String,
        in spec: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let components = try XCTUnwrap(spec["components"] as? [String: Any], file: file, line: line)
        let schemas = try XCTUnwrap(components["schemas"] as? [String: Any], file: file, line: line)
        return try XCTUnwrap(schemas[name] as? [String: Any], "components.schemas.\(name) missing", file: file, line: line)
    }

    private func colorItemSchema(in envelope: [String: Any], spec: [String: Any]) throws -> [String: Any] {
        let properties = try XCTUnwrap(envelope["properties"] as? [String: Any])
        let colors = try XCTUnwrap(properties["colors"] as? [String: Any])
        let items = try XCTUnwrap(colors["items"] as? [String: Any])
        guard let ref = items["$ref"] as? String else { return items }
        let name = try XCTUnwrap(ref.split(separator: "/").last.map(String.init))
        return try resolveSchema(name, in: spec)
    }

    private func schemaProperties(_ schema: [String: Any]) -> Set<String> {
        Set((schema["properties"] as? [String: Any] ?? [:]).keys)
    }

    private func schemaRequired(_ schema: [String: Any]) -> [String] {
        schema["required"] as? [String] ?? []
    }
}
