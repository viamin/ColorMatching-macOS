import XCTest
@testable import ColorComposerCore

/// Pins the `/api/v1` wire shapes to the server's published OpenAPI 3 contract
/// (viamin/color_matching#113, `ColorMatchingWeb.ApiSchemas`): every payload
/// below is built from exactly the properties the spec marks required
/// (`PrinterProfilesResponse`, `ColorsResponse`, `PrinterProfile`, `Rgb`), and
/// each must decode through this app's DTOs. The generated OpenAPI client must
/// keep satisfying these shapes — a renamed or newly-required field shows up
/// here before it ships.
final class OpenAPIContractTests: XCTestCase {
    private func decode<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: Data(json.utf8))
    }

    /// Spec: color items require `id`, `name`, `hex`, `palette_id`,
    /// `sort_order`, `responses`; `rgb` and `palette_name` are optional.
    func testSpecRequiredColorFieldsDecode() throws {
        let color = try decode(
            """
            {"id":123,"name":"Red 12","hex":"#C64A35",
             "palette_id":5,"sort_order":12,
             "responses":{"red":{"brightness":0.87}}}
            """,
            as: PaletteColorDTO.self
        )

        XCTAssertEqual(color.id, 123)
        XCTAssertEqual(color.name, "Red 12")
        XCTAssertEqual(color.hex, "#C64A35")
        XCTAssertEqual(color.paletteId, 5)
        XCTAssertEqual(color.sortOrder, 12)
        XCTAssertEqual(color.responses["red"]?.brightness, 0.87)
        XCTAssertNil(color.rgb)
        XCTAssertNil(color.paletteName)
    }

    func testSpecOptionalRgbObjectDecodes() throws {
        let color = try decode(
            """
            {"id":123,"name":"Red 12","hex":"#C64A35",
             "palette_id":5,"sort_order":12,
             "rgb":{"r":198,"g":74,"b":53},
             "palette_name":"Default",
             "responses":{"lps":{"brightness":0.52}}}
            """,
            as: PaletteColorDTO.self
        )

        XCTAssertEqual(color.rgb?.r, 198)
        XCTAssertEqual(color.rgb?.g, 74)
        XCTAssertEqual(color.rgb?.b, 53)
        XCTAssertEqual(color.paletteName, "Default")
    }

    /// Spec: `PrinterProfile` requires all four fields.
    func testSpecRequiredPrinterProfileFieldsDecode() throws {
        let profile = try decode(
            """
            {"id":4,"printer_make_model":"Epson","paper_type":"Matte","ink_type":"Dye"}
            """,
            as: PrinterProfileDTO.self
        )

        XCTAssertEqual(profile.id, 4)
        XCTAssertEqual(profile.printerMakeModel, "Epson")
        XCTAssertEqual(profile.paperType, "Matte")
        XCTAssertEqual(profile.inkType, "Dye")
    }

    func testSpecRequiredPrinterProfilesEnvelopeDecodes() throws {
        let envelope = try decode(
            """
            {"printer_profiles":[{"id":1,"printer_make_model":"Epson","paper_type":"Matte","ink_type":"Dye"}]}
            """,
            as: PrinterProfilesResponse.self
        )

        XCTAssertEqual(envelope.printerProfiles.count, 1)
        XCTAssertEqual(envelope.printerProfiles.first?.id, 1)
    }

    /// Spec: the colors envelope requires `printer_profile` and `colors`.
    /// The client additionally tolerates the envelope without a profile so an
    /// older deployment omitting it still loads colors.
    func testSpecRequiredColorsEnvelopeDecodes() throws {
        let envelope = try decode(
            """
            {"printer_profile":{"id":4,"printer_make_model":"Epson","paper_type":"Matte","ink_type":"Dye"},
             "colors":[{"id":123,"name":"Red 12","hex":"#C64A35",
                        "palette_id":5,"sort_order":12,
                        "responses":{"red":{"brightness":0.87}}}]}
            """,
            as: ColorsResponse.self
        )

        XCTAssertEqual(envelope.printerProfile?.id, 4)
        XCTAssertEqual(envelope.colors.map(\.id), [123])
    }

    /// The spec's `light_source` enum is `["white","red","green","blue","lps"]`;
    /// `LightingCondition` is this app's single source of truth for that set
    /// and must match it exactly.
    func testSpecLightSourceEnumMatchesLightingConditions() {
        XCTAssertEqual(
            LightingCondition.all.map(\.rawValue),
            ["white", "red", "green", "blue", "lps"]
        )
    }
}
