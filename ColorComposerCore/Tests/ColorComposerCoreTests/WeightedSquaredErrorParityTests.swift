import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the versioned golden vectors produced by `color_matching`.
///
/// The fixture deliberately includes exact ties, exclusions for missing
/// measurements, zero-weight channels, and unknown channels.
final class WeightedSquaredErrorParityTests: XCTestCase {
    func testWeightedSquaredErrorMatchesVersionOneParityCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let target = TargetResponseVector(scenario.target.channels.knownLightingConditions)
        let weights = ChannelWeights(channels: scenario.weights)
        let candidates = try scenario.palette.map { try PaletteColor(parityCandidate: $0) }
        let actualScores = candidates.map {
            scorer.score(candidate: $0, target: target, weights: weights)
        }

        XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
        for (actual, expected) in zip(actualScores, scenario.expected.scores) {
            XCTAssertEqual(expected.index, scenario.palette[expected.index].index, scenario.id)
            switch (actual, expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actualScore), .value(let expectedScore)):
                XCTAssertEqual(actualScore, expectedScore, scenario.id)
            default:
                XCTFail("Score mismatch for candidate \(expected.index) in \(scenario.id)")
            }
        }

        var selectedIndex: Int?
        var selectedScore = Double.infinity
        for (index, score) in actualScores.enumerated() {
            guard case .score(let value) = score, value < selectedScore else { continue }
            selectedIndex = index
            selectedScore = value
        }

        XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, scenario.id)
        XCTAssertEqual(selectedIndex.map { candidates[$0].hex }, scenario.expected.selectedHexColor, scenario.id)
        XCTAssertEqual(selectedIndex.flatMap { actualScores[$0].value }, scenario.expected.error, scenario.id)

        let tiedIndices = tiedIndices(in: actualScores, selectedIndex: selectedIndex)
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
        XCTAssertEqual(
            tiedIndices.count > 1 ? true : false,
            scenario.expected.tieBroke ?? false,
            scenario.id
        )
    }

    private func tiedIndices(in scores: [ScorerResult], selectedIndex: Int?) -> [Int] {
        guard let selectedIndex, case .score(let selectedScore) = scores[selectedIndex] else { return [] }
        return scores.enumerated().compactMap { index, score in
            guard case .score(let value) = score, value == selectedScore else { return nil }
            return index
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: file))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityCandidate]
    let target: ParityCandidate
    let weights: [String: Double]
    let expected: ParityExpectation
}

private struct ParityCandidate: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpectation: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    enum Score: Equatable {
        case excluded
        case value(Double)
    }

    let index: Int
    let score: Score

    private enum CodingKeys: String, CodingKey {
        case index
        case score
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        if let value = try? container.decode(Double.self, forKey: .score) {
            score = .value(value)
        } else {
            let encoded = try container.decode(String.self, forKey: .score)
            guard encoded == "excluded" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .score,
                    in: container,
                    debugDescription: "Expected a numeric score or excluded."
                )
            }
            score = .excluded
        }
    }
}

private extension Dictionary where Key == String, Value == Double {
    var knownLightingConditions: [LightingCondition: Double] {
        reduce(into: [:]) { result, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            result[condition] = entry.value
        }
    }
}

private extension ChannelWeights {
    init(channels: [String: Double]) {
        self.init(
            white: channels[LightingCondition.white.rawValue] ?? 0,
            red: channels[LightingCondition.red.rawValue] ?? 0,
            green: channels[LightingCondition.green.rawValue] ?? 0,
            blue: channels[LightingCondition.blue.rawValue] ?? 0,
            lps: channels[LightingCondition.lps.rawValue] ?? 0
        )
    }
}

private extension PaletteColor {
    init(parityCandidate candidate: ParityCandidate) throws {
        guard let rgb = RGBColor(hex: candidate.hexColor) else {
            throw NSError(domain: "ParityCorpus", code: 1)
        }
        self.init(
            id: candidate.index ?? -1,
            hex: candidate.hexColor,
            rgb: rgb,
            responses: candidate.channels.knownLightingConditions.mapValues(IlluminationResponse.init(brightness:))
        )
    }
}

private extension ScorerResult {
    var value: Double? {
        guard case .score(let value) = self else { return nil }
        return value
    }
}
