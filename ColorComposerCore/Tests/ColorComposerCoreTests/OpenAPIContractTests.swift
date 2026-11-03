import Foundation
import XCTest
@testable import ColorComposerCore

/// Pins the OpenAPI contract the app's API client is built from.
///
/// The `color_matching` server publishes its OpenAPI 3 document at
/// `GET /api/v1/openapi.json` (viamin/color_matching PR #113). The app keeps
/// a copy of that document in the package and generates its typed client from
/// it, so the document is the contract both sides are checked against: it must
/// document the endpoints the client calls, with the response shapes the
/// client decodes.
final class OpenAPIContractTests: XCTestCase {
    /// Filename of the OpenAPI document committed in the package.
    static let documentFilename = "openapi.json"

    /// Root of the `ColorComposerCore` package (the parent of `Tests`).
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The package must ship the document the typed client is generated from,
    /// so the client and the contract cannot drift apart unnoticed.
    func testPackageCommitsExactlyOneOpenAPIDocument() throws {
        let documents = openAPIDocuments()

        XCTAssertEqual(
            documents.count,
            1,
            """
            expected exactly one \(Self.documentFilename) under \(packageRoot.path) — the document the \
            typed client is generated from; found \(documents.map(\.path)). See docs/openapi-client.md.
            """
        )

        let document = try XCTUnwrap(documents.first)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: document)) as? [String: Any]
        )
        let version = try XCTUnwrap(
            root["openapi"] as? String,
            "\(document.lastPathComponent) has no openapi version"
        )
        XCTAssertTrue(version.hasPrefix("3."), "expected an OpenAPI 3 document, found \(version)")
    }

    /// The package must depend on the OpenAPI runtime the generated client
    /// runs on.
    func testPackageDependsOnTheOpenAPIRuntime() throws {
        let manifestURL = packageRoot.appendingPathComponent("Package.swift")
        let manifest = String(decoding: try Data(contentsOf: manifestURL), as: UTF8.self)

        XCTAssertTrue(
            manifest.contains("swift-openapi-runtime"),
            "ColorComposerCore/Package.swift must depend on swift-openapi-runtime"
        )
    }

    /// The document must describe the two endpoints the palette client uses.
    func testDocumentDescribesTheEndpointsTheClientUses() throws {
        let document = try loadDocument()
        let paths = try XCTUnwrap(document["paths"] as? [String: Any], "the document has no paths")

        XCTAssertNotNil(paths["/api/v1/printer_profiles"], "GET /api/v1/printer_profiles is not documented")
        XCTAssertNotNil(paths["/api/v1/colors"], "GET /api/v1/colors is not documented")

        let colors = try XCTUnwrap(paths["/api/v1/colors"] as? [String: Any])
        let operation = try XCTUnwrap(colors["get"] as? [String: Any], "GET /api/v1/colors has no get operation")
        let parameters = try XCTUnwrap(
            operation["parameters"] as? [[String: Any]],
            "GET /api/v1/colors documents no parameters"
        )
        let queryParameters = parameters.filter { ($0["in"] as? String) == "query" }

        XCTAssertTrue(
            queryParameters.contains { ($0["name"] as? String) == "printer_profile_id" },
            "GET /api/v1/colors must document the printer_profile_id query parameter"
        )
    }

    /// The documented response shapes must be the shapes the client decodes:
    /// the envelope property names and the printer-profile fields are the
    /// wire contract, whichever client implementation is behind them.
    func testDocumentDescribesTheResponseShapesTheClientDecodes() throws {
        let document = try loadDocument()

        let profiles = try responseSchema(for: "/api/v1/printer_profiles", in: document)
        let profilesProperties = try XCTUnwrap(profiles["properties"] as? [String: Any])
        XCTAssertNotNil(
            profilesProperties["printer_profiles"],
            "the /printer_profiles response must carry a printer_profiles array"
        )

        let colors = try responseSchema(for: "/api/v1/colors", in: document)
        let colorsProperties = try XCTUnwrap(colors["properties"] as? [String: Any])
        XCTAssertNotNil(
            colorsProperties["printer_profile"],
            "the /colors response must carry the printer_profile it belongs to"
        )
        XCTAssertNotNil(colorsProperties["colors"], "the /colors response must carry a colors array")

        let profileSchema = try resolve(
            try XCTUnwrap(colorsProperties["printer_profile"] as? [String: Any]),
            in: document
        )
        let profileProperties = try XCTUnwrap(profileSchema["properties"] as? [String: Any])
        for field in ["id", "printer_make_model", "paper_type", "ink_type"] {
            XCTAssertNotNil(profileProperties[field], "the documented printer profile must carry \(field)")
        }
    }

    // MARK: - Helpers

    /// The committed OpenAPI document, parsed.
    private func loadDocument() throws -> [String: Any] {
        let documents = openAPIDocuments()
        let document = try XCTUnwrap(
            documents.first,
            """
            no \(Self.documentFilename) found under \(packageRoot.path) — commit the server's OpenAPI \
            document there so the typed client can be generated from it (see docs/openapi-client.md).
            """
        )
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: document))
        return try XCTUnwrap(object as? [String: Any])
    }

    /// Every OpenAPI document committed in the package.
    private func openAPIDocuments() -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: packageRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == Self.documentFilename {
            found.append(url)
        }
        return found.sorted { $0.path < $1.path }
    }

    /// The 200 response schema of `path`, with local `$ref`s resolved.
    private func responseSchema(for path: String, in document: [String: Any]) throws -> [String: Any] {
        let paths = try XCTUnwrap(document["paths"] as? [String: Any])
        let pathItem = try XCTUnwrap(paths[path] as? [String: Any], "\(path) is not documented")
        let operation = try XCTUnwrap(pathItem["get"] as? [String: Any], "\(path) has no get operation")
        let responses = try XCTUnwrap(operation["responses"] as? [String: Any], "\(path) has no responses")
        let ok = try XCTUnwrap(responses["200"] as? [String: Any], "\(path) has no 200 response")
        let content = try XCTUnwrap(ok["content"] as? [String: Any], "\(path) 200 response has no content")
        let json = try XCTUnwrap(
            content["application/json"] as? [String: Any],
            "\(path) 200 response has no application/json content"
        )
        let schema = try XCTUnwrap(json["schema"] as? [String: Any], "\(path) 200 response has no schema")
        return try resolve(schema, in: document)
    }

    /// Resolves a local `$ref` (`#/components/schemas/Name`) into the schema
    /// it points at.
    private func resolve(_ schema: [String: Any], in document: [String: Any]) throws -> [String: Any] {
        guard let reference = schema["$ref"] as? String else { return schema }

        let components = try XCTUnwrap(document["components"] as? [String: Any], "the document has no components")
        let schemas = try XCTUnwrap(components["schemas"] as? [String: Any], "the document has no component schemas")
        let parts = reference.split(separator: "/")
        let name = parts.isEmpty ? reference : String(parts[parts.count - 1])
        return try XCTUnwrap(schemas[name] as? [String: Any], "unresolved reference \(reference)")
    }
}
