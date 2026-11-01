import Foundation
@testable import ColorComposerCore

/// Bridges corpus scenarios into the solver's domain models, applying the
/// same unknown-light-source filtering as the wire decoder in
/// `PaletteColorDTO.toDomain()`.
extension ParityCorpus.Scenario {
    /// Weights restricted to canonical light sources, mirroring the Elixir
    /// scorer's `filter_weights/1`: unknown sources (e.g. `ultraviolet`)
    /// are ignored rather than rejected.
    var channelWeights: ChannelWeights {
        ChannelWeights(
            white: weights["white"] ?? 0,
            red: weights["red"] ?? 0,
            green: weights["green"] ?? 0,
            blue: weights["blue"] ?? 0,
            lps: weights["lps"] ?? 0
        )
    }

    /// The scenario target; absent channels stay unmeasured (missing), never zero.
    var targetVector: TargetResponseVector {
        TargetResponseVector(brightnessDictionary(from: target.channels))
    }

    /// Candidates in palette order — indices must match the corpus `index`
    /// fields so selection parity can be asserted positionally.
    var paletteColors: [PaletteColor] {
        palette.map { entry in
            PaletteColor(
                id: entry.index ?? 0,
                hex: entry.hexColor,
                rgb: RGBColor(hex: entry.hexColor)!,
                responses: responseDictionary(from: entry.channels)
            )
        }
    }

    private func brightnessDictionary(
        from channels: [String: Double]
    ) -> [LightingCondition: Double] {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in channels {
            if let condition = LightingCondition(rawValue: key) {
                brightness[condition] = value
            }
        }
        return brightness
    }

    private func responseDictionary(
        from channels: [String: Double]
    ) -> [LightingCondition: IlluminationResponse] {
        brightnessDictionary(from: channels).mapValues {
            IlluminationResponse(brightness: $0)
        }
    }
}
