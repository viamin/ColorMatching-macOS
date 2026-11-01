import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesVersionOneParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = TargetResponseVector(responses(from: scenario.target.channels))
            let weights = weights(from: scenario.weights)
            let palette = try scenario.palette.map(makePaletteColor)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
            for (actual, expected) in zip(actualScores, scenario.expected.scores) {
                XCTAssertEqual(Optional(expected.index), scenario.palette[expected.index].index, scenario.id)
                assert(actual, matches: expected.score, scenarioID: scenario.id, index: expected.index)
            }

            let selection = selectEarliest(palette, target: target, weights: weights, scorer: scorer)
            XCTAssertEqual(selection.index, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(selection.hexColor, scenario.expected.selectedHexColor, scenario.id)
            assert(selection.error, matches: scenario.expected.error, scenarioID: scenario.id, index: selection.index)
            XCTAssertEqual(tiedIndices(actualScores, error: selection.error), scenario.expected.tiedIndices, scenario.id)
            XCTAssertEqual(
                scenario.expected.tieBroke,
                scenario.expected.selectedIndex.map { _ in scenario.expected.tiedIndices.count > 1 },
                scenario.id
            )
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixtureURL = testDirectory.appendingPathComponent("Fixtures/parity/v1/corpus.json")
        let data = try Data(contentsOf: fixtureURL)
        return try JSONDecoder().decode(ParityCorpus.self, from: data)
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func weights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0],
            red: values["red", default: 0],
            green: values["green", default: 0],
            blue: values["blue", default: 0],
            lps: values["lps", default: 0]
        )
    }

    private func makePaletteColor(_ vector: ParityVector) throws -> PaletteColor {
        guard let rgb = RGBColor(hex: vector.hexColor) else {
            throw ParityFixtureError.invalidHex(vector.hexColor)
        }
        guard let index = vector.index else {
            throw ParityFixtureError.missingPaletteIndex(vector.hexColor)
        }
        let illumination = responses(from: vector.channels).mapValues { IlluminationResponse(brightness: $0) }
        return PaletteColor(id: index, hex: vector.hexColor, rgb: rgb, responses: illumination)
    }

    private func selectEarliest(
        _ palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights,
        scorer: WeightedSquaredErrorScorer
    ) -> (index: Int?, hexColor: String?, error: Double?) {
        var best: (index: Int, hexColor: String, error: Double)?
        for (index, candidate) in palette.enumerated() {
            guard case .score(let error) = scorer.score(candidate: candidate, target: target, weights: weights) else {
                continue
            }
            if best == nil || error < best!.error {
                best = (index, candidate.hex, error)
            }
        }
        return (best?.index, best?.hexColor, best?.error)
    }

    private func tiedIndices(_ scores: [ScorerResult], error: Double?) -> [Int] {
        guard let error else { return [] }
        return scores.enumerated().compactMap { index, result in
            guard case .score(let score) = result, score == error else { return nil }
            return index
        }
    }

    private func assert(
        _ actual: ScorerResult,
        matches expected: ParityScore,
        scenarioID: String,
        index: Int
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .value(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "\\(scenarioID), candidate \\(index)")
        default:
            XCTFail("\\(scenarioID), candidate \\(index): expected \\(expected), got \\(actual)")
        }
    }

    private func assert(
        _ actual: Double?,
        matches expected: Double?,
        scenarioID: String,
        index: Int?
    ) {
        switch (actual, expected) {
        case (nil, nil):
            break
        case let (.some(actual), .some(expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "\\(scenarioID), selected candidate \\(String(describing: index))")
        default:
            XCTFail("\\(scenarioID): expected selection error \\(String(describing: expected)), got \\(String(describing: actual))")
        }
    }
}

private enum ParityFixtureError: Error {
    case invalidHex(String)
    case missingPaletteIndex(String)
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let selection: String
    let missingPolicy: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: ParityVector
    let palette: [ParityVector]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScoredCandidate]
    let selectedIndex: Int?
    let selectedHexColor: String?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScoredCandidate: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable, CustomStringConvertible {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .value(let value): return String(value)
        }
    }
}
