import Foundation

/// The finite set of illuminants under which printable colors are measured
/// and source images are authored.
///
/// Raw values match the `light_source` strings used by the `color_matching`
/// API (`white`, `red`, `green`, `blue`, `lps`) so palette data decodes without
/// translation. This enum is the single source of truth for lighting conditions
/// — never hard-code condition strings elsewhere.
public enum LightingCondition: String, CaseIterable, Sendable, Codable, Hashable {
    case white
    case red
    case green
    case blue
    case lps

    /// Short human-readable label for UI.
    public var displayName: String {
        switch self {
        case .white: return "White"
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        case .lps: return "LPS (Sodium)"
        }
    }
    /// Representative color used to tint per-channel lighting previews, so a
    /// "Preview · Red" reads as the image viewed under red light. Each channel
    /// maps from black to this tint by predicted brightness. White yields a
    /// neutral grayscale preview; LPS uses the amber of low-pressure sodium.
    public var displayTint: (red: Double, green: Double, blue: Double) {
        switch self {
        case .white: return (1, 1, 1)
        case .red: return (1, 0, 0)
        case .green: return (0, 1, 0)
        case .blue: return (0, 0, 1)
        case .lps: return (1.0, 0.55, 0.0)
        }
    }

    /// All conditions in a stable canonical order matching the server.
    public static var all: [LightingCondition] { allCases }
}
