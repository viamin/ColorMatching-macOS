import Foundation

/// Color space in which source brightness is interpreted during sampling.
///
/// Source grayscale values arrive as 8-bit sRGB-encoded channel values.
/// `gamma` keeps the normalized `value / 255` (matching the `color_matching`
/// mapper); `linear` decodes each value to linear luminance via the sRGB
/// transfer function, for physically-correct matching under colored light.
public enum BrightnessColorSpace: String, Sendable, Codable, CaseIterable {
    /// sRGB-encoded gamma space — the raw normalized channel value (`v / 255`).
    /// The default, keeping client and server in agreement.
    case gamma

    /// Linear luminance — the gamma value decoded to linear light.
    case linear

    /// Decodes a normalized gamma-space value (`0 ... 1`) into this color space.
    public func decode(_ gammaValue: Double) -> Double {
        switch self {
        case .gamma:
            return gammaValue
        case .linear:
            return Self.gammaToLinear(gammaValue)
        }
    }

    /// sRGB electro-optical transfer function: converts a normalized sRGB
    /// (gamma-encoded) value to linear luminance.
    public static func gammaToLinear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
