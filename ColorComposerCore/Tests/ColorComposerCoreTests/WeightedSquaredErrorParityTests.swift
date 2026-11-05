import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testMatchesCommittedColorMatchingParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1, "Refresh this test with the matching solver implementation when the corpus version changes.")

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let target = TargetResponseVector(responses(from: scenario.target.channels))
        let palette = try scenario.palette.map(makePaletteColor)
        let weights = makeWeights(from: scenario.weights)
        let actualScores = palette.map { WeightedSquaredErrorScorer().score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
        for expected in scenario.expected.scores {
            XCTAssertEqual(actualScores[expected.index], expected.score.scorerResult, "\(scenario.id), candidate \(expected.index)")
        }

        let selected = selectedIndex(in: actualScores)
        XCTAssertEqual(selected, scenario.expected.selectedIndex, scenario.id)
        XCTAssertEqual(selected.map { palette[$0].hex }, scenario.expected.selectedHexColor, scenario.id)
        XCTAssertEqual(selected.flatMap { actualScores[$0].score }, scenario.expected.error, scenario.id)
        XCTAssertEqual(tiedIndices(in: actualScores, selected: selected), scenario.expected.tiedIndices, scenario.id)
        XCTAssertEqual(scenario.expected.tieBroke, scenario.expected.tiedIndices.count > 1, scenario.id)
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fileURL))
    }

    private func makePaletteColor(_ candidate: ParityCandidate) throws -> PaletteColor {
        guard let rgb = RGBColor(hex: candidate.hexColor) else {
            throw ParityFixtureError.invalidHexColor(candidate.hexColor)
        }
        return PaletteColor(
            id: candidate.index,
            hex: candidate.hexColor,
            rgb: rgb,
            responses: responses(from: candidate.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        channels.reduce(into: [:]) { responses, entry in
            if let condition = LightingCondition(rawValue: entry.key) {
                responses[condition] = entry.value
            }
        }
    }

    private func makeWeights(from weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white"] ?? 0,
            red: weights["red"] ?? 0,
            green: weights["green"] ?? 0,
            blue: weights["blue"] ?? 0,
            lps: weights["lps"] ?? 0
        )
    }

    private func selectedIndex(in scores: [ScorerResult]) -> Int? {
        scores.enumerated().reduce(into: nil as (index: Int, score: Double)?) { best, item in
            guard case .score(let score) = item.element else { return }
            if best == nil || score < best!.score { best = (item.offset, score) }
        }?.index
    }

    private func tiedIndices(in scores: [ScorerResult], selected: Int?) -> [Int] {
        guard let selected, case .score(let bestScore) = scores[selected] else { return [] }
        return scores.enumerated().compactMap { index, score in
            score.score == bestScore ? index : nil
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scenarios: [ParityScenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case scenarios
    }
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityCandidate]
    let target: ParityCandidate
    let weights: [String: Double]
    let expected: ParityExpectation
}

private struct ParityCandidate: Decodable {
    let index: Int
    let hexColor: String
    let channels: [String: Double]

    enum CodingKeys: String, CodingKey {
        case index
        case hexColor = "hex_color"
        case channels
    }
}

private struct ParityExpectation: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool
    let tiedIndices: [Int]

    enum CodingKeys: String, CodingKey {
        case error, scores
        case selectedHexColor = "selected_hex_color"
        case selectedIndex = "selected_index"
        case tieBroke = "tie_broke"
        case tiedIndices = "tied_indices"
    }
}

private struct ParityExpectedScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable {
    case score(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .score(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }

    var scorerResult: ScorerResult {
        switch self {
        case .score(let value): return .score(value)
        case .excluded: return .excluded
        }
    }
}

private extension ScorerResult {
    var score: Double? {
        guard case .score(let value) = self else { return nil }
        return value
    }
}

private enum ParityFixtureError: Error {
    case invalidHexColor(String)
}
