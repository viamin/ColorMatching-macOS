import Foundation
import XCTest
@testable import ColorComposerCore

/// Pins the `/api/v1` wire shapes that `PaletteAPIClient` decodes to the
/// response schemas published in `color_matching`'s OpenAPI document
/// (`GET /api/v1/openapi.json`, built from `ColorMatchingWeb.ApiSchemas`).
///
/// The payloads below are the *minimal* responses valid under the spec
/// (required properties only, plus the spec's nullable/optional markers).
/// They must keep decoding through the real client so the generated-client
/// migration cannot silently change what the app accepts. Shape findings and
/// the refresh procedure live in `docs/solver-parity-corpus.md`.
final class APIv1OpenAPIContractTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - GET /api/v1/colors

    func testColorsDecodesMinimalSpecConformantResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/colors")
            XCTAssertEqual(request.url?.query, "printer_profile_id=3")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), Self.minimalColorsResponse)
        }

        let (colors, profile) = try await client.fetchColors(printerProfileID: 3)

        XCTAssertEqual(profile?.id, 3)
        XCTAssertEqual(profile?.printerMakeModel, "Epson P700")
        XCTAssertEqual(colors.count, 1)
        XCTAssertEqual(colors[0].id, 11)
        XCTAssertEqual(colors[0].name, "Cadmium Red")
        XCTAssertEqual(colors[0].hex, "#E34234")
        XCTAssertEqual(colors[0].paletteId, 2)
        XCTAssertEqual(colors[0].sortOrder, 1)
        XCTAssertNil(colors[0].paletteName)

        let domain = try XCTUnwrap(colors[0].toDomain())
        XCTAssertEqual(domain.brightness(for: .red), 0.875)
        XCTAssertEqual(domain.brightness(for: .white), 0.5)
        XCTAssertNil(domain.brightness(for: .lps), "unmeasured channels must stay absent")
    }

    func testColorsDecodesNullablePaletteNameAndOptionalRgb() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.nullableFieldsColorsResponse)
        }

        let (colors, _) = try await client.fetchColors(printerProfileID: 3)

        XCTAssertNil(colors[0].paletteName)
        XCTAssertEqual(colors[0].rgb?.r, 227)
        let domain = try XCTUnwrap(colors[0].toDomain())
        XCTAssertEqual(domain.rgb.red, 227)
    }

    // MARK: - GET /api/v1/printer_profiles

    func testPrinterProfilesDecodesMinimalSpecConformantResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
            return (.init(statusCode: 200, url: request.url!), Self.minimalPrinterProfilesResponse)
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].id, 1)
        XCTAssertEqual(profiles[0].printerMakeModel, "Canon Pro-300")
        XCTAssertEqual(profiles[0].paperType, "Gloss")
        XCTAssertEqual(profiles[0].inkType, "Dye")
    }

    // MARK: - Fixtures

    /// Minimal `ColorsResponse` per the spec: `printer_profile` and `colors`
    /// are required; each color requires `id`, `name`, `hex`, `palette_id`,
    /// `sort_order`, `responses` (optional `rgb` / nullable `palette_name`
    /// omitted). `responses` entries use the documented shape from PR #84.
    private static let minimalColorsResponse = """
        {
          "printer_profile": {
            "id": 3,
            "printer_make_model": "Epson P700",
            "paper_type": "Matte",
            "ink_type": "Pigment"
          },
          "colors": [
            {
              "id": 11,
              "name": "Cadmium Red",
              "hex": "#E34234",
              "palette_id": 2,
              "sort_order": 1,
              "responses": {
                "red": { "brightness": 0.875, "source": "response" },
                "white": { "brightness": 0.5 }
              }
            }
          ]
        }
        """.data(using: .utf8)!

    /// Same shape exercising the optional `rgb` object and the spec's
    /// `palette_name: null` nullable marker.
    private static let nullableFieldsColorsResponse = """
        {
          "printer_profile": {
            "id": 3,
            "printer_make_model": "Epson P700",
            "paper_type": "Matte",
            "ink_type": "Pigment"
          },
          "colors": [
            {
              "id": 12,
              "name": "Cobalt Blue",
              "hex": "#0047AB",
              "rgb": { "r": 0, "g": 71, "b": 171 },
              "palette_id": 2,
              "palette_name": null,
              "sort_order": 2,
              "responses": {}
            }
          ]
        }
        """.data(using: .utf8)!

    /// Minimal `PrinterProfilesResponse` per the spec: one profile carrying
    /// all required properties.
    private static let minimalPrinterProfilesResponse = """
        {
          "printer_profiles": [
            {
              "id": 1,
              "printer_make_model": "Canon Pro-300",
              "paper_type": "Gloss",
              "ink_type": "Dye"
            }
          ]
        }
        """.data(using: .utf8)!

    private func makeClient(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(baseURL: URL(string: "http://example.com")!, session: session)
    }
}
