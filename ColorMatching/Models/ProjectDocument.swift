import Foundation
import ColorComposerCore

/// Serializable snapshot of a composition project for save/open.
struct ProjectDocument: Codable {
    var serverBaseURL: String
    var apiToken: String
    var printerProfileID: Int?
    var colorSnapshot: [ColorSnapshot]
    var weights: ChannelWeights
    var scorerKind: ScorerKind
    var logicalWidth: Int
    var logicalHeight: Int
    var pixelsPerCell: Int
    var physicalWidthMM: Double
    var physicalHeightMM: Double
    var layers: [LayerSnapshot]

    private enum CodingKeys: String, CodingKey {
        case serverBaseURL, apiToken, printerProfileID, colorSnapshot
        case weights, scorerKind
        case logicalWidth, logicalHeight, pixelsPerCell
        case physicalWidthMM, physicalHeightMM, layers
    }

    init(
        serverBaseURL: String,
        apiToken: String,
        printerProfileID: Int?,
        colorSnapshot: [ColorSnapshot],
        weights: ChannelWeights,
        scorerKind: ScorerKind,
        logicalWidth: Int,
        logicalHeight: Int,
        pixelsPerCell: Int,
        physicalWidthMM: Double,
        physicalHeightMM: Double,
        layers: [LayerSnapshot]
    ) {
        self.serverBaseURL = serverBaseURL
        self.apiToken = apiToken
        self.printerProfileID = printerProfileID
        self.colorSnapshot = colorSnapshot
        self.weights = weights
        self.scorerKind = scorerKind
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.pixelsPerCell = pixelsPerCell
        self.physicalWidthMM = physicalWidthMM
        self.physicalHeightMM = physicalHeightMM
        self.layers = layers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverBaseURL = try c.decode(String.self, forKey: .serverBaseURL)
        apiToken = try c.decode(String.self, forKey: .apiToken)
        printerProfileID = try c.decodeIfPresent(Int.self, forKey: .printerProfileID)
        colorSnapshot = try c.decode([ColorSnapshot].self, forKey: .colorSnapshot)
        weights = try c.decode(ChannelWeights.self, forKey: .weights)
        // Older projects predate scorer choice; default to the v1 scorer so
        // they round-trip identically to how they were originally solved.
        scorerKind = try c.decodeIfPresent(ScorerKind.self, forKey: .scorerKind) ?? .weightedSquaredError
        logicalWidth = try c.decode(Int.self, forKey: .logicalWidth)
        logicalHeight = try c.decode(Int.self, forKey: .logicalHeight)
        pixelsPerCell = try c.decode(Int.self, forKey: .pixelsPerCell)
        physicalWidthMM = try c.decode(Double.self, forKey: .physicalWidthMM)
        physicalHeightMM = try c.decode(Double.self, forKey: .physicalHeightMM)
        layers = try c.decode([LayerSnapshot].self, forKey: .layers)
    }
}

struct LayerSnapshot: Codable {
    var imageData: Data
    var filename: String?
    var assignedCondition: LightingCondition?
    var inverted: Bool
    var scalingMode: ImageScalingMode
    var colorSpace: BrightnessColorSpace = .gamma

    init(
        imageData: Data,
        filename: String?,
        assignedCondition: LightingCondition?,
        inverted: Bool,
        scalingMode: ImageScalingMode,
        colorSpace: BrightnessColorSpace = .gamma
    ) {
        self.imageData = imageData
        self.filename = filename
        self.assignedCondition = assignedCondition
        self.inverted = inverted
        self.scalingMode = scalingMode
        self.colorSpace = colorSpace
    }

    private enum CodingKeys: String, CodingKey {
        case imageData, filename, assignedCondition, inverted, scalingMode, colorSpace
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imageData = try c.decode(Data.self, forKey: .imageData)
        filename = try c.decodeIfPresent(String.self, forKey: .filename)
        assignedCondition = try c.decodeIfPresent(LightingCondition.self, forKey: .assignedCondition)
        inverted = try c.decode(Bool.self, forKey: .inverted)
        scalingMode = try c.decode(ImageScalingMode.self, forKey: .scalingMode)
        // Older projects predate the color-space option; default to gamma so
        // they round-trip identically to how they were originally authored.
        colorSpace = try c.decodeIfPresent(BrightnessColorSpace.self, forKey: .colorSpace) ?? .gamma
    }
}

/// Codable mirror of `PaletteColor` with String-keyed responses, recording the
/// measured colors used at generation time with the project. (Named for the
/// color it wraps; the "palette" grouping is not part of the project format.)
struct ColorSnapshot: Codable {
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

    func toColor() -> PaletteColor {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, value) in self.responses {
            if let condition = LightingCondition(rawValue: key) {
                responses[condition] = value
            }
        }
        return PaletteColor(id: id, name: name, hex: hex, rgb: rgb, responses: responses)
    }
}
