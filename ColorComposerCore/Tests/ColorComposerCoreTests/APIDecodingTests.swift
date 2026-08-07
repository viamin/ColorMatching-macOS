import XCTest
@testable import ColorComposerCore

final class APIDecodingTests: XCTestCase {
    private func decode<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: Data(json.utf8))
    }

    func testDecodesColorsResponseWithResponses() throws {
        let json = """
        {
          "printer_profile": {
            "id": 1, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"
          },
          "colors": [
            {
              "id": 123, "name": "Red 12", "hex": "#C64A35",
              "rgb": {"r": 198, "g": 74, "b": 53},
              "palette_id": 5, "palette_name": "Default", "sort_order": 12,
              "responses": {
                "red": {"brightness": 0.87, "source": "measurement", "raw_value": null, "raw_unit": null, "apparent_brightness": null, "measured_at": null, "test_run_id": null},
                "lps": {"brightness": 0.52, "source": "response", "apparent_brightness": 5, "raw_value": null, "raw_unit": null, "measured_at": null, "test_run_id": null}
              }
            }
          ]
        }
        """
        let envelope = try decode(json, as: ColorsResponse.self)
        XCTAssertEqual(envelope.colors.count, 1)
        XCTAssertEqual(envelope.printerProfile?.id, 1)

        let color = try XCTUnwrap(envelope.colors.first)
        XCTAssertEqual(color.id, 123)
        XCTAssertEqual(color.name, "Red 12")
        XCTAssertEqual(color.rgb?.r, 198)
        XCTAssertEqual(color.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(color.responses["red"]?.source, "measurement")
        XCTAssertEqual(color.responses["lps"]?.apparentBrightness, 5)

        // green/blue/white are absent (missing measurement).
        XCTAssertNil(color.responses["green"])
        XCTAssertNil(color.responses["blue"])
        XCTAssertNil(color.responses["white"])
    }

    func testMissingMeasurementsAreAbsentNotZero() throws {
        let json = """
        {"colors":[{"id":1,"hex":"#000000","rgb":{"r":0,"g":0,"b":0},"responses":{}}]}
        """
        let envelope = try decode(json, as: ColorsResponse.self)
        let color = try XCTUnwrap(envelope.colors.first)
        XCTAssertTrue(color.responses.isEmpty)
    }

    func testDomainConversionDropsUnknownLightSources() throws {
        let json = """
        {"colors":[{"id":7,"hex":"#abcdef","rgb":{"r":171,"g":205,"b":239},
          "responses":{
            "red":{"brightness":0.5},
            "ultraviolet":{"brightness":0.9}
          }}]}
        """
        let envelope = try decode(json, as: ColorsResponse.self)
        let dto = try XCTUnwrap(envelope.colors.first)
        let domain = try XCTUnwrap(dto.toDomain())

        XCTAssertEqual(domain.id, 7)
        XCTAssertEqual(domain.brightness(for: .red), 0.5)
        XCTAssertNil(domain.brightness(for: .green))
        XCTAssertEqual(domain.rgb.red, 171)
    }

    func testDomainConversionFallsBackToHexWhenRGBOmitted() throws {
        let json = """
        {"colors":[{"id":1,"hex":"#112233","responses":{}}]}
        """
        let envelope = try decode(json, as: ColorsResponse.self)
        let domain = try XCTUnwrap(try XCTUnwrap(envelope.colors.first).toDomain())
        XCTAssertEqual(domain.rgb, RGBColor(hex: "#112233"))
    }

    func testDecodesPalettesAndProfiles() throws {
        let palettes = try decode(
            #"{"palettes":[{"id":1,"name":"A","is_preset":false,"color_count":42}]}"#,
            as: PalettesResponse.self
        )
        XCTAssertEqual(palettes.palettes.first?.colorCount, 42)

        let profiles = try decode(
            #"{"printer_profiles":[{"id":1,"printer_make_model":"Epson","paper_type":"Matte","ink_type":"Dye"}]}"#,
            as: PrinterProfilesResponse.self
        )
        XCTAssertEqual(profiles.printerProfiles.first?.id, 1)
    }
}
