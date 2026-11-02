import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the golden vectors published by `color_matching`.
final class WeightedSquaredErrorParityTests: XCTestCase {
    func testPublishedParityCorpusMatchesScoresSelectionsAndTies() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertFalse(corpus.scenarios.isEmpty)

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let weights = scenario.weights.channelWeights
        let target = TargetResponseVector(scenario.target.channels.responses)
        let palette = scenario.palette
            .sorted { $0.index < $1.index }
            .map { $0.paletteColor }
        let expectedScores = scenario.expected.scores.sorted { $0.index < $1.index }

        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
        XCTAssertEqual(actualScores.count, expectedScores.count, scenario.id)
        for (actual, expected) in zip(actualScores, expectedScores) {
            switch expected.score {
            case .excluded:
                XCTAssertEqual(actual, .excluded, scenario.id)
            case .value(let value):
                XCTAssertEqual(actual, .score(value), scenario.id)
            }
        }

        let selected = earliestBestIndex(in: actualScores)
        XCTAssertEqual(selected, scenario.expected.selectedIndex, scenario.id)
        if let selected {
            XCTAssertEqual(palette[selected].hex, scenario.expected.selectedHexColor, scenario.id)
            guard case .score(let error) = actualScores[selected] else {
                return XCTFail("\(scenario.id): selected candidate was excluded")
            }
            XCTAssertEqual(error, scenario.expected.error, scenario.id)
        } else {
            XCTAssertNil(scenario.expected.error, scenario.id)
        }

        let ties = tiedIndices(in: actualScores, selected: selected)
        XCTAssertEqual(ties, scenario.expected.tiedIndices, scenario.id)
        XCTAssertEqual(scenario.expected.tieBroke, ties.count > 1 ? true : (selected == nil ? nil : false), scenario.id)
    }

    private func earliestBestIndex(in scores: [ScorerResult]) -> Int? {
        var best: (index: Int, error: Double)?
        for (index, score) in scores.enumerated() {
            guard case .score(let error) = score else { continue }
            if best == nil || error < best!.error {
                best = (index, error)
            }
        }
        return best?.index
    }

    private func tiedIndices(in scores: [ScorerResult], selected: Int?) -> [Int] {
        guard let selected, case .score(let error) = scores[selected] else { return [] }
        return scores.enumerated().compactMap { index, score in
            guard case .score(let candidateError) = score, candidateError == error else { return nil }
            return index
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case scorer, selection, scenarios
    }
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: ParityChannels
    let expected: ParityExpected
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]

    enum CodingKeys: String, CodingKey {
        case error, scores
        case selectedHexColor = "selected_hex_color"
        case selectedIndex = "selected_index"
        case tieBroke = "tie_broke"
        case tiedIndices = "tied_indices"
    }
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ParityScoreValue
}

private enum ParityScoreValue: Decodable {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else {
            guard try container.decode(String.self) == "excluded" else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
            }
            self = .excluded
        }
    }
}

private struct ParityVector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: ParityChannels

    enum CodingKeys: String, CodingKey {
        case index, channels
        case hexColor = "hex_color"
    }

    var paletteColor: PaletteColor {
        PaletteColor(
            id: index ?? -1,
            hex: hexColor,
            rgb: RGBColor(hex: hexColor)!,
            responses: channels.responses.mapValues { IlluminationResponse(brightness: $0) }
        )
    }
}

private struct ParityChannels: Decodable {
    let white: Double?
    let red: Double?
    let green: Double?
    let blue: Double?
    let lps: Double?

    var responses: [LightingCondition: Double] {
        [(.white, white), (.red, red), (.green, green), (.blue, blue), (.lps, lps)]
            .compactMap { condition, value in value.map { (condition, $0) } }
            .reduce(into: [:]) { $0[$1.0] = $1.1 }
    }

    var channelWeights: ChannelWeights {
        ChannelWeights(white: white ?? 0, red: red ?? 0, green: green ?? 0, blue: blue ?? 0, lps: lps ?? 0)
    }
}
