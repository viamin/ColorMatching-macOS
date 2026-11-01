import Foundation
import XCTest
@testable import ColorComposerCore

/// Guards the contract between the committed OpenAPI document for
/// `color_matching`'s `/api/v1` API (viamin/color_matching#110) and the wire
/// shapes this app decodes in `APIModels.swift` / `PaletteAPIClient.swift`.
///
/// The document is vendored at `Fixtures/openapi.json` next to this file.
/// When the server spec changes shape, these tests fail and name the exact
/// property that drifted — that is the machine-checked half of "record any
/// /api/v1 shape changes found" from issue #39.
final class OpenAPIContractTests: XCTestCase {
    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/openapi.json")
    }

    private enum ContractError: Error, CustomStringConvertible {
        case fixtureMissing(String)
        case malformed(String)

        var description: String {
            switch self {
            case .fixtureMissing(let path):
                return """
                    OpenAPI document is not committed: expected it at \(path). \
                    Vendor the spec published by viamin/color_matching#110 there \
                    so the generated client and these contract checks share one \
                    source of truth.
                    """
            case .malformed(let detail):
                return "OpenAPI document does not match the expected structure: \(detail)"
            }
        }
    }

    // MARK: - Document

    func testOpenAPIDocumentIsCommittedAndVersioned() throws {
        let document = try loadDocument()

        let version = try stringChild("openapi", of: document, "document root")
        XCTAssertTrue(version.hasPrefix("3."), "expected an OpenAPI 3.x document, found \(version)")
    }

    // MARK: - /api/v1/printer_profiles

    func testPrinterProfilesEndpointMatchesWireContract() throws {
        let document = try loadDocument()
        let operation = try getOperation("GET", "/api/v1/printer_profiles", document)
        let envelope = try successSchema(of: operation, document)
        let profilesSchema = try resolvedSchema(
            try schemaChild("printer_profiles", of: envelope, "printer_profiles response"), in: document
        )

        try assertIsArray(profilesSchema, "printer_profiles")
        let profile = try resolvedSchema(
            try objectChild("items", of: profilesSchema, "printer_profiles items"), in: document
        )
        assertProperties(profile, contain: ["id", "printer_make_model", "paper_type", "ink_type"],
                         in: "printer profile object decoded by PrinterProfileDTO")
    }

    // MARK: - /api/v1/colors

    func testColorsEndpointRequiresPrinterProfileIDQuery() throws {
        let document = try loadDocument()
        let operation = try getOperation("GET", "/api/v1/colors", document)
        let parameters = try arrayChild("parameters", of: operation, "GET /api/v1/colors")

        let parameter = parameters
            .compactMap { $0 as? [String: Any] }
            .first { $0["name"] as? String == "printer_profile_id" }
        let queryItem = try XCTUnwrap(parameter,
                                      "GET /api/v1/colors must declare a printer_profile_id query parameter")

        XCTAssertEqual(queryItem["in"] as? String, "query")
        XCTAssertEqual(queryItem["required"] as? Bool, true,
                       "printer_profile_id must be required, as PaletteAPIClient always sends it")
    }

    func testColorsEndpointMatchesWireContract() throws {
        let document = try loadDocument()
        let operation = try getOperation("GET", "/api/v1/colors", document)
        let envelope = try successSchema(of: operation, document)

        XCTAssertNotNil(envelope["colors"], "missing colors envelope property")
        XCTAssertNotNil(envelope["printer_profile"], "missing printer_profile envelope property decoded by ColorsResponse")

        let color = try resolvedSchema(
            try objectChild("items", of: try resolvedSchema(
                try schemaChild("colors", of: envelope, "colors response"), in: document
            ), "colors items"), in: document
        )
        assertProperties(
            color,
            contain: ["id", "name", "hex", "rgb", "palette_id", "palette_name", "sort_order", "responses"],
            in: "palette color object decoded by PaletteColorDTO"
        )

        let rgb = try resolvedSchema(try schemaChild("rgb", of: color, "color rgb"), in: document)
        assertProperties(rgb, contain: ["r", "g", "b"], in: "rgb object decoded by RGBDTO")
    }

    func testColorResponsesMatchWireContract() throws {
        let document = try loadDocument()
        let color = try colorItemSchema(document)
        let responses = try resolvedSchema(try schemaChild("responses", of: color, "color responses"), in: document)

        let valueSchema: [String: Any]
        if let additional = responses["additionalProperties"] {
            valueSchema = try resolvedSchema(
                try OpenAPIContractTests.object(additional, "responses additionalProperties"), in: document
            )
        } else if let defined = responses["properties"] as? [String: Any] {
            valueSchema = try resolvedSchema(
                try OpenAPIContractTests.object(defined.first?.value, "responses properties"), in: document
            )
        } else {
            return XCTFail("responses map must declare its value schema via additionalProperties or properties")
        }

        assertProperties(
            valueSchema,
            contain: ["brightness", "source", "raw_value", "raw_unit", "apparent_brightness"],
            in: "illuminant response object decoded by ColorResponseDTO"
        )
    }

    func testResponsesMapAcceptsEveryCanonicalLightSource() throws {
        let document = try loadDocument()
        let color = try colorItemSchema(document)
        let responses = try resolvedSchema(try schemaChild("responses", of: color, "color responses"), in: document)

        guard let keyConstraint = responses["propertyNames"] as? [String: Any],
              let enumValues = keyConstraint["enum"] as? [String] else { return }
        let allowed = Set(enumValues)

        for condition in LightingCondition.all {
            XCTAssertTrue(allowed.contains(condition.rawValue),
                          "spec restricts response keys to \(enumValues.sorted()) but the client sends/decodes '\(condition.rawValue)'")
        }
    }

    // MARK: - Navigation helpers

    private func loadDocument() throws -> [String: Any] {
        let url = Self.fixtureURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ContractError.fixtureMissing(url.path)
        }
        let data = try Data(contentsOf: url)
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ContractError.malformed("unreadable JSON: \(error)")
        }
        guard let object = root as? [String: Any] else {
            throw ContractError.malformed("root is not a JSON object")
        }
        return object
    }

    private func getOperation(_ method: String, _ path: String, _ document: [String: Any]) throws -> [String: Any] {
        let paths = try objectChild("paths", of: document, "document root")
        let pathItem = try objectChild(path, of: paths, "paths")
        return try objectChild(method.lowercased(), of: pathItem, path)
    }

    private func successSchema(of operation: [String: Any], _ document: [String: Any]) throws -> [String: Any] {
        let responses = try objectChild("responses", of: operation, "operation")
        let ok = try objectChild("200", of: responses, "responses")
        let content = try objectChild("content", of: ok, "200 response")
        let json = try objectChild("application/json", of: content, "content")
        return try resolvedSchema(try objectChild("schema", of: json, "application/json"), in: document)
    }

    private func resolvedSchema(_ schema: [String: Any], in document: [String: Any]) throws -> [String: Any] {
        var current = schema
        for _ in 0..<8 {
            guard let reference = current["$ref"] as? String else { return current }
            guard reference.hasPrefix("#/components/schemas/") else {
                throw ContractError.malformed("unsupported $ref '\(reference)' (expected a local components/schemas reference)")
            }
            let name = String(reference.dropFirst("#/components/schemas/".count))
            let components = try objectChild("components", of: document, "document root")
            let schemas = try objectChild("schemas", of: components, "components")
            current = try objectChild(name, of: schemas, "components/schemas")
        }
        throw ContractError.malformed("$ref chain did not terminate")
    }

    private func colorItemSchema(_ document: [String: Any]) throws -> [String: Any] {
        let operation = try getOperation("GET", "/api/v1/colors", document)
        let envelope = try successSchema(of: operation, document)
        let colorsArray = try resolvedSchema(
            try schemaChild("colors", of: envelope, "colors response"), in: document
        )
        return try resolvedSchema(
            try objectChild("items", of: colorsArray, "colors items"), in: document
        )
    }

    private func assertProperties(_ schema: [String: Any], contain keys: [String], in what: String) {
        let properties = schema["properties"] as? [String: Any] ?? [:]
        for key in keys {
            XCTAssertNotNil(properties[key], "spec is missing property '\(key)' expected by \(what)")
        }
    }

    private func assertIsArray(_ schema: [String: Any], _ what: String) throws {
        if let type = schema["type"] as? String {
            XCTAssertEqual(type, "array", "\(what) must be an array type")
        } else if let types = schema["type"] as? [Any] {
            XCTAssertTrue(types.contains { $0 as? String == "array" },
                          "\(what) must include the array type")
        } else {
            throw ContractError.malformed("\(what) has no type")
        }
    }

    // MARK: - Typed child access

    private static func object(_ value: Any?, _ what: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw ContractError.malformed("\(what) is not an object")
        }
        return object
    }

    private func objectChild(_ key: String, of parent: [String: Any], _ what: String) throws -> [String: Any] {
        try Self.object(parent[key], "\(what) → \(key)")
    }

    private func schemaChild(_ key: String, of parent: [String: Any], _ what: String) throws -> [String: Any] {
        guard let child = parent[key] else {
            throw ContractError.malformed("\(what) → \(key) is missing")
        }
        if let schema = child as? [String: Any] { return schema }
        if child is [Any] {
            throw ContractError.malformed("\(what) → \(key) is an array; expected an object schema")
        }
        throw ContractError.malformed("\(what) → \(key) is not a schema object")
    }

    private func stringChild(_ key: String, of parent: [String: Any], _ what: String) throws -> String {
        guard let string = parent[key] as? String else {
            throw ContractError.malformed("\(what) → \(key) is missing or not a string")
        }
        return string
    }

    private func arrayChild(_ key: String, of parent: [String: Any], _ what: String) throws -> [Any] {
        guard let array = parent[key] as? [Any] else {
            throw ContractError.malformed("\(what) → \(key) is missing or not an array")
        }
        return array
    }
}
