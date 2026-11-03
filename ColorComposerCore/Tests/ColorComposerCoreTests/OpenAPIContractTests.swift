import Foundation
import XCTest

/// The app's API client is generated from the OpenAPI document the
/// `color_matching` backend publishes at `GET /api/v1/openapi.json`.
///
/// The document is vendored in the package so the generated client can be
/// regenerated from a checkout. These tests pin the parts of that document
/// the app depends on: the endpoints the client calls, the response shapes
/// it decodes, and the bearer authentication it sends. They are the contract
/// the generated client has to keep satisfying — a change on the server that
/// moves a field or relaxes a required property shows up here first.
final class OpenAPIContractTests: XCTestCase {
    /// The documented endpoint that lists the available printer profiles.
    func testVendoredOpenAPIDocumentDeclaresTheEndpointsTheClientUses() throws {
        let document = try Self.document()
        let paths = try XCTUnwrap(document["paths"] as? [String: Any], "The OpenAPI document has no paths object.")

        let profiles = try XCTUnwrap(
            paths["/api/v1/printer_profiles"] as? [String: Any],
            "The OpenAPI document does not declare GET /api/v1/printer_profiles."
        )
        XCTAssertNotNil(profiles["get"], "GET /api/v1/printer_profiles is not declared.")

        let colors = try XCTUnwrap(
            paths["/api/v1/colors"] as? [String: Any],
            "The OpenAPI document does not declare GET /api/v1/colors."
        )
        let colorsGet = try XCTUnwrap(colors["get"] as? [String: Any], "GET /api/v1/colors is not declared.")
        let parameters = try XCTUnwrap(
            colorsGet["parameters"] as? [[String: Any]],
            "GET /api/v1/colors declares no parameters."
        )
        let profileParameter = try XCTUnwrap(
            parameters.first { ($0["name"] as? String) == "printer_profile_id" },
            "GET /api/v1/colors does not declare the printer_profile_id parameter."
        )
        XCTAssertEqual(profileParameter["in"] as? String, "query")
        XCTAssertEqual(profileParameter["required"] as? Bool, true)
    }

    /// The response shapes the client decodes into `PrinterProfileDTO` and
    /// `PaletteColorDTO`.
    func testVendoredOpenAPIDocumentDeclaresTheResponseShapesTheClientDecodes() throws {
        let document = try Self.document()
        let schemas = try XCTUnwrap(
            Self.components(document)["schemas"] as? [String: Any],
            "The OpenAPI document declares no component schemas."
        )

        let profilesResponse = try XCTUnwrap(
            schemas["PrinterProfilesResponse"] as? [String: Any],
            "The OpenAPI document declares no PrinterProfilesResponse schema."
        )
        XCTAssertEqual(Set(Self.requiredFields(profilesResponse)), ["printer_profiles"])
        let profilesArray = try XCTUnwrap(
            Self.properties(profilesResponse)["printer_profiles"] as? [String: Any]
        )
        XCTAssertEqual(profilesArray["type"] as? String, "array")

        let printerProfile = try XCTUnwrap(
            schemas["PrinterProfile"] as? [String: Any],
            "The OpenAPI document declares no PrinterProfile schema."
        )
        XCTAssertEqual(
            Set(Self.requiredFields(printerProfile)),
            ["id", "printer_make_model", "paper_type", "ink_type"]
        )

        let colorsResponse = try XCTUnwrap(
            schemas["ColorsResponse"] as? [String: Any],
            "The OpenAPI document declares no ColorsResponse schema."
        )
        XCTAssertEqual(Set(Self.requiredFields(colorsResponse)), ["printer_profile", "colors"])
        XCTAssertNotNil(Self.properties(colorsResponse)["printer_profile"])

        let colorsArray = try XCTUnwrap(Self.properties(colorsResponse)["colors"] as? [String: Any])
        XCTAssertEqual(colorsArray["type"] as? String, "array")
        let colorItem = try XCTUnwrap(colorsArray["items"] as? [String: Any])
        XCTAssertEqual(
            Set(Self.requiredFields(colorItem)),
            ["id", "name", "hex", "palette_id", "sort_order", "responses"]
        )
        XCTAssertNotNil(Self.properties(colorItem)["rgb"])
        XCTAssertNotNil(Self.properties(colorItem)["palette_name"])
    }

    /// The API is token protected when the server is configured with one, so
    /// the document has to describe the bearer scheme the client sends.
    func testVendoredOpenAPIDocumentDeclaresBearerAuthentication() throws {
        let document = try Self.document()
        let securitySchemes = try XCTUnwrap(
            Self.components(document)["securitySchemes"] as? [String: Any],
            "The OpenAPI document declares no security schemes."
        )
        let bearer = try XCTUnwrap(
            securitySchemes["bearerAuth"] as? [String: Any],
            "The OpenAPI document declares no bearerAuth security scheme."
        )
        XCTAssertEqual(bearer["type"] as? String, "http")
        XCTAssertEqual(bearer["scheme"] as? String, "bearer")
    }

    // MARK: - Helpers

    /// The vendored OpenAPI document.
    private static func document() throws -> [String: Any] {
        let url = try OpenAPIDocumentLocator.url()
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "The vendored OpenAPI document is not a JSON object."
        )
    }

    private static func components(_ document: [String: Any]) -> [String: Any] {
        document["components"] as? [String: Any] ?? [:]
    }

    private static func properties(_ schema: [String: Any]) -> [String: Any] {
        schema["properties"] as? [String: Any] ?? [:]
    }

    private static func requiredFields(_ schema: [String: Any]) -> [String] {
        schema["required"] as? [String] ?? []
    }
}

/// Finds the OpenAPI document vendored in the package.
private enum OpenAPIDocumentLocator {
    /// Where the document may live, relative to the package root.
    static let candidatePaths = [
        "openapi.json",
        "Sources/ColorComposerCore/Resources/openapi.json",
        "OpenAPI/openapi.json"
    ]

    /// The vendored document.
    static func url() throws -> URL {
        guard let root = TestFixtureLocator.packageRoot else {
            throw DocumentError.packageRootNotFound
        }
        for path in candidatePaths {
            let candidate = TestFixtureLocator.appending(path, to: root)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw DocumentError.missing(candidatePaths: candidatePaths)
    }

    /// Raised when the document has not been vendored yet.
    enum DocumentError: Error, CustomStringConvertible {
        case packageRootNotFound
        case missing(candidatePaths: [String])

        var description: String {
            switch self {
            case .packageRootNotFound:
                return "Could not locate the ColorComposerCore package root."
            case .missing(let candidatePaths):
                return """
                    The published OpenAPI document is not vendored in the package. \
                    Fetch it from the color_matching server (GET /api/v1/openapi.json) \
                    and commit it as one of: \(candidatePaths.joined(separator: ", ")).
                    """
            }
        }
    }
}
