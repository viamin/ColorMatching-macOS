import Foundation

/// One measured illuminant response for a palette color under a single
/// lighting condition.
///
/// `brightness` is the normalized `0.0 ... 1.0` value used by the solver.
/// The raw provenance (`source`, `rawValue`, `apparentBrightness`) is preserved
/// for display but does not affect matching.
public struct IlluminationResponse: Sendable, Codable, Equatable, Hashable {
    /// Normalized brightness in `0.0 ... 1.0` used for matching.
    public let brightness: Double

    /// Origin of the value: `"response"` (human-entered 0–10 score) or
    /// `"measurement"` (instrument reading).
    public let source: String?

    /// Raw 0–10 apparent-brightness score, when the value came from a response.
    public let apparentBrightness: Int?

    /// Raw instrument reading and its unit, when available.
    public let rawValue: Double?
    public let rawUnit: String?

    public init(
        brightness: Double,
        source: String? = nil,
        apparentBrightness: Int? = nil,
        rawValue: Double? = nil,
        rawUnit: String? = nil
    ) {
        self.brightness = brightness
        self.source = source
        self.apparentBrightness = apparentBrightness
        self.rawValue = rawValue
        self.rawUnit = rawUnit
    }
}

/// A single printable color entry and its measured behavior under each
/// lighting condition.
///
/// Conditions without a measurement are simply absent from `responses`, so
/// "missing" is distinguishable from "measured as zero brightness" — matching
/// the `color_matching` data model and the solver's exclusion policy.
public struct PaletteColor: Sendable, Identifiable, Equatable, Hashable {
    public let id: Int
    public var name: String?
    public var hex: String
    public var rgb: RGBColor
    public var paletteID: Int?
    public var paletteName: String?
    public var sortOrder: Int?
    public var responses: [LightingCondition: IlluminationResponse]

    public init(
        id: Int,
        name: String? = nil,
        hex: String,
        rgb: RGBColor,
        paletteID: Int? = nil,
        paletteName: String? = nil,
        sortOrder: Int? = nil,
        responses: [LightingCondition: IlluminationResponse] = [:]
    ) {
        self.id = id
        self.name = name
        self.hex = hex
        self.rgb = rgb
        self.paletteID = paletteID
        self.paletteName = paletteName
        self.sortOrder = sortOrder
        self.responses = responses
    }

    /// Normalized brightness for a condition, or `nil` when unmeasured.
    public func brightness(for condition: LightingCondition) -> Double? {
        responses[condition]?.brightness
    }

    /// `true` when the color has a measurement for every condition in `required`.
    public func hasMeasurements(for required: Set<LightingCondition>) -> Bool {
        required.allSatisfy { responses[$0] != nil }
    }
}
