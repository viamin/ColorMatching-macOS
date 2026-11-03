import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testCommittedV1CorpusMatchesScoresAndSelections() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: Scenario, file: StaticString = #filePath, line: UInt = #line) throws {
        let weights = makeWeights(scenario.weights)
        let target = TargetResponseVector(makeChannels(scenario.target.channels))
        let palette = try scenario.palette.map(makePaletteColor)
        let scorer = WeightedSquaredErrorScorer()

        for expectedScore in scenario.expected.scores {
            let result = scorer.score(
                candidate: palette[expectedScore.index], target: target, weights: weights
            )
            assert(result, matches: expectedScore.score, scenarioID: scenario.id, file: file, line: line)
        }

        let selectedIndex = select(palette: palette, target: target, weights: weights)
        XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, scenario.id, file: file, line: line)
        if let selectedIndex = scenario.expected.selectedIndex {
            XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor, scenario.id, file: file, line: line)
        }

        guard hasTargetValueForEveryActiveChannel(scenario.target.channels, weights: weights) else { return }
        let sourceGrids = makeSourceGrids(target: scenario.target.channels, weights: weights)
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: sourceGrids, weights: weights)
        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id, file: file, line: line)
        if let expectedError = scenario.expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id, file: file, line: line)
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id, file: file, line: line)
        }
    }

    private func assert(
        _ actual: ScorerResult,
        matches expected: ExpectedScore,
        scenarioID: String,
        file: StaticString,
        line: UInt
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, scenarioID, file: file, line: line)
        default:
            XCTFail("\\(scenarioID): expected \\(expected), received \\(actual)", file: file, line: line)
        }
    }

    private func loadCorpus() throws -> Corpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let corpusURL = testFile.deletingLastPathComponent().appendingPathComponent("Resources/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: corpusURL))
    }

    private func makePaletteColor(_ candidate: Candidate) throws -> PaletteColor {
        guard let rgb = RGBColor(hex: candidate.hexColor) else {
            throw FixtureError.invalidHex(candidate.hexColor)
        }
        guard let index = candidate.index else {
            throw FixtureError.missingPaletteIndex(candidate.hexColor)
        }
        return PaletteColor(
            id: index,
            hex: candidate.hexColor,
            rgb: rgb,
            responses: makeChannels(candidate.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func makeChannels(_ channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, value in
            LightingCondition(rawValue: name).map { ($0, value) }
        })
    }

    private func makeWeights(_ weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white"] ?? 0,
            red: weights["red"] ?? 0,
            green: weights["green"] ?? 0,
            blue: weights["blue"] ?? 0,
            lps: weights["lps"] ?? 0
        )
    }

    private func makeSourceGrids(
        target: [String: Double],
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeEntries.map { condition, _ in
            (condition, BrightnessGrid(width: 1, height: 1, values: [target[condition.rawValue] ?? 0]))
        })
    }

    private func select(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> Int? {
        let scorer = WeightedSquaredErrorScorer()
        var best: (index: Int, score: Double)?
        for (index, candidate) in palette.enumerated() {
            guard case .score(let score) = scorer.score(candidate: candidate, target: target, weights: weights) else {
                continue
            }
            if best == nil || score < best!.score {
                best = (index, score)
            }
        }
        return best?.index
    }

    private func hasTargetValueForEveryActiveChannel(
        _ target: [String: Double],
        weights: ChannelWeights
    ) -> Bool {
        weights.activeEntries.allSatisfy { target[$0.condition.rawValue] != nil }
    }
}

private enum FixtureError: Error {
    case invalidHex(String)
    case missingPaletteIndex(String)
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let palette: [Candidate]
    let target: Candidate
    let weights: [String: Double]
    let expected: Expected
}

private struct Candidate: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct Expected: Decodable {
    let error: Double?
    let scores: [ScoredCandidate]
    let selectedHexColor: String?
    let selectedIndex: Int?
}

private struct ScoredCandidate: Decodable {
    let index: Int
    let score: ExpectedScore
}

private enum ExpectedScore: Decodable {
    case excluded
    case score(Double)

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
}
