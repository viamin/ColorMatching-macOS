import Foundation
import ColorComposerCore

/// Serializable snapshot of a composition project for save/open.
struct ProjectDocument: Codable {
    var serverBaseURL: String
    var apiToken: String
    var printerProfileID: Int?
    var paletteID: Int?
    var paletteName: String?
    var paletteSnapshot: [PaletteColorSnapshot]
    var weights: ChannelWeights
    var logicalWidth: Int
    var logicalHeight: Int
    var pixelsPerCell: Int
    var physicalWidthMM: Double
    var physicalHeightMM: Double
    var layers: [LayerSnapshot]
}

struct LayerSnapshot: Codable {
    var imageData: Data
    var filename: String?
    var assignedCondition: LightingCondition?
    var inverted: Bool
    var scalingMode: ImageScalingMode
}

/// Codable mirror of `PaletteColor` with String-keyed responses, so the palette
/// used at generation time is recorded with the project.
struct PaletteColorSnapshot: Codable {
    var id: Int
    var name: String?
    var hex: String
    var rgb: RGBColor
    var responses: [String: IlluminationResponse]

    init(_ color: PaletteColor) {
        id = color.id
        name = color.name
        hex = color.hex
        rgb = color.rgb
        responses = color.responses.reduce(into: [:]) { result, entry in
            result[entry.key.rawValue] = entry.value
        }
    }

    func toPaletteColor() -> PaletteColor {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, value) in self.responses {
            if let condition = LightingCondition(rawValue: key) {
                responses[condition] = value
            }
        }
        return PaletteColor(id: id, name: name, hex: hex, rgb: rgb, responses: responses)
    }
}
