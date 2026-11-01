import Foundation
@testable import ColorComposerCore

/// Decoded form of the solver parity corpus (`priv/parity/v1/corpus.json`)
/// published by the `color_matching` server.
///
/// The corpus records, for deterministic scenarios, the exact per-candidate
/// scores, the selected palette index, and tie-break evidence produced by the
/// Elixir `ColorMatching.WeightedSquaredError` solver, so the Swift
/// `WeightedSquaredErrorScorer` can be held to exact agreement.
struct ParityCorpus: Decodable {
    struct Candidate: Decodable {
        let index: Int
        let hexColor: String
        /// Channel name → measured brightness. A channel absent from this map
        /// is *missing* (unmeasured), never zero.
        let channels: [String: Double]

        enum CodingKeys: String, CodingKey {
            case index
            case hexColor = "hex_color"
            case channels
        }
    }

    struct Vector: Decodable {
        let channels: [String: Double]

        enum CodingKeys: String, CodingKey {
            case channels
        }
    }

    /// A per-candidate outcome: either a numeric score or the string
    /// `"excluded"` for candidates the server refused to rank.
    enum ParityScore: Decodable, Equatable {
        case value(Double)
        case excluded

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let raw = try? container.decode(String.self), raw == "excluded" {
                self = .excluded
            } else {
                self = .value(try container.decode(Double.self))
            }
        }
    }

    struct Expected: Decodable {
        struct ScoreEntry: Decodable {
            let index: Int
            let score: ParityScore
        }

        let scores: [ScoreEntry]
        let error: Double?
        let selectedIndex: Int?
        let selectedHexColor: String?
        let tieBroke: Bool?
        let tiedIndices: [Int]

        enum CodingKeys: String, CodingKey {
            case scores
            case error
            case selectedIndex = "selected_index"
            case selectedHexColor = "selected_hex_color"
            case tieBroke = "tie_broke"
            case tiedIndices = "tied_indices"
        }
    }

    struct Scenario: Decodable {
        let id: String
        let description: String
        let palette: [Candidate]
        let target: Vector
        /// Channel name → weight. Unknown channel names must be ignored.
        let weights: [String: Double]
        let expected: Expected
    }

    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scorer: String
    let selection: String
    let scenarios: [Scenario]

    enum CodingKeys: String, CodingKey {
        case scenarios
        case scorer
        case selection
        case algorithmVersion = "algorithm_version"
        case lightSources = "light_sources"
        case missingPolicy = "missing_policy"
    }

    static func load() throws -> ParityCorpus {
        try JSONDecoder().decode(ParityCorpus.self, from: Data(ParityCorpusV1Data.json.utf8))
    }
}

// MARK: - Domain mapping

extension ChannelWeights {
    /// Builds weights from the corpus map. Keys that are not canonical
    /// lighting conditions (e.g. `"ultraviolet"`) are ignored, mirroring the
    /// corpus's `unknown-weight-ignored` scenario.
    init(parityWeights: [String: Double]) {
        self.init()
        for (key, value) in parityWeights {
            guard let condition = LightingCondition(rawValue: key) else { continue }
            switch condition {
            case .white: white = value
            case .red: red = value
            case .green: green = value
            case .blue: blue = value
            case .lps: lps = value
            }
        }
    }
}

extension ParityCorpus.Candidate {
    /// Converts to the solver's domain model. Unmeasured channels are absent
    /// from `responses`; non-canonical channel keys are dropped.
    func toPaletteColor() -> PaletteColor? {
        guard let rgb = RGBColor(hex: hexColor) else { return nil }
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, brightness) in channels {
            guard let condition = LightingCondition(rawValue: key) else { continue }
            responses[condition] = IlluminationResponse(brightness: brightness)
        }
        return PaletteColor(id: index, hex: hexColor, rgb: rgb, responses: responses)
    }
}

extension ParityCorpus.Vector {
    func toTarget() -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in channels {
            guard let condition = LightingCondition(rawValue: key) else { continue }
            brightness[condition] = value
        }
        return TargetResponseVector(brightness)
    }
}
