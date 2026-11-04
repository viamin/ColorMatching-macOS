import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the backend-owned golden vectors, including ties, exclusions, and
/// zero-weight channels. The fixture's source is color_matching#111.
final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedParityCorpusExactly() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])

        for scenario in corpus.scenarios {
            assertScorerParity(for: scenario)
            try assertSolverParityWhenRepresentable(for: scenario)
        }
    }

    private func assertScorerParity(for scenario: ParityScenario) {
        let scorer = WeightedSquaredErrorScorer()
        let weights = makeWeights(scenario.weights)
        let target = makeTarget(scenario.target)
        let palette = scenario.palette.sorted { $0.index! < $1.index! }.map(makeColor)
        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
        for (actual, expected) in zip(actualScores, scenario.expected.scores.sorted { $0.index < $1.index }) {
            assertScore(actual, equals: expected.score, scenarioID: scenario.id)
        }

        let selection = earliestSelection(from: actualScores)
        XCTAssertEqual(selection.index, scenario.expected.selectedIndex, scenario.id)
        XCTAssertEqual(selection.score, scenario.expected.error, scenario.id)
        XCTAssertEqual(selection.tiedIndices, scenario.expected.tiedIndices, scenario.id)
        if selection.index == nil {
            XCTAssertNil(scenario.expected.tieBroke, scenario.id)
        } else {
            XCTAssertEqual(selection.tiedIndices.count > 1, scenario.expected.tieBroke == true, scenario.id)
        }
        XCTAssertEqual(
            selection.index.map { palette[$0].hex },
            scenario.expected.selectedHexColor,
            scenario.id
        )
    }

    private func assertSolverParityWhenRepresentable(for scenario: ParityScenario) throws {
        let weights = makeWeights(scenario.weights)
        guard weights.activeConditions.allSatisfy({ scenario.target.channels[$0.rawValue] != nil }) else {
            // CompositionSolver builds targets from required source grids, while
            // the corpus also intentionally covers a missing target response.
            return
        }

        let palette = scenario.palette.sorted { $0.index! < $1.index! }.map(makeColor)
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: makeSourceGrids(scenario.target, weights: weights),
            weights: weights
        )

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
        if let expectedError = scenario.expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
        }
    }

    private func assertScore(_ actual: ScorerResult, equals expected: ParityScore, scenarioID: String) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, scenarioID)
        default:
            XCTFail("\(scenarioID): scorer result did not match corpus")
        }
    }

    private func earliestSelection(from scores: [ScorerResult]) -> ParitySelection {
        var selectedIndex: Int?
        var selectedScore: Double?
        for (index, result) in scores.enumerated() {
            guard case .score(let score) = result else { continue }
            if selectedScore == nil || score < selectedScore! {
                selectedIndex = index
                selectedScore = score
            }
        }
        let tiedIndices = scores.enumerated().compactMap { index, result -> Int? in
            guard case .score(let score) = result, selectedScore.map({ score == $0 }) == true else { return nil }
            return index
        }
        return ParitySelection(index: selectedIndex, score: selectedScore, tiedIndices: tiedIndices)
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makeTarget(_ fixture: ParityVector) -> TargetResponseVector {
        TargetResponseVector(Dictionary(uniqueKeysWithValues: fixture.channels.compactMap { entry in
            LightingCondition(rawValue: entry.key).map { ($0, entry.value) }
        }))
    }

    private func makeColor(_ fixture: ParityVector) -> PaletteColor {
        let responses = Dictionary(uniqueKeysWithValues: fixture.channels.compactMap { entry in
            LightingCondition(rawValue: entry.key).map { ($0, IlluminationResponse(brightness: entry.value)) }
        })
        return PaletteColor(
            id: fixture.index!,
            hex: fixture.hexColor,
            rgb: RGBColor(hex: fixture.hexColor)!,
            responses: responses
        )
    }

    private func makeWeights(_ fixture: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: fixture["white", default: 0], red: fixture["red", default: 0],
            green: fixture["green", default: 0], blue: fixture["blue", default: 0],
            lps: fixture["lps", default: 0]
        )
    }

    private func makeSourceGrids(_ target: ParityVector, weights: ChannelWeights) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [target.channels[condition.rawValue]!]))
        })
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: ParityVector
    let palette: [ParityVector]
    let expected: ParityExpectedResult
}

private struct ParityVector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpectedResult: Decodable {
    let error: Double?
    let scores: [ParityCandidateScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityCandidateScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable {
    case score(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let score = try? value.decode(Double.self) {
            self = .score(score)
        } else if try value.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Expected score or excluded")
        }
    }
}

private struct ParitySelection {
    let index: Int?
    let score: Double?
    let tiedIndices: [Int]
}
