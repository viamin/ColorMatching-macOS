import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testCorpusMetadataDescribesTheMirroredServerContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true }, "Corpus must retain tie cases")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil }, "Corpus must retain all-excluded cases")
    }

    func testWeightedSquaredErrorScorerMatchesEveryRecordedCandidateScore() throws {
        let scorer = WeightedSquaredErrorScorer()

        for scenario in try loadCorpus().scenarios {
            let target = target(for: scenario.target)
            let weights = weights(for: scenario.weights)

            for expectedScore in scenario.expected.scores {
                let candidate = try XCTUnwrap(scenario.palette.first { $0.index == expectedScore.index })
                let actual = scorer.score(candidate: color(for: candidate), target: target, weights: weights)
                assert(actual, matches: expectedScore.score, scenarioID: scenario.id, index: expectedScore.index)
            }
        }
    }

    func testCompositionSolverMatchesEveryRecordedSelectionAndTie() throws {
        let solver = CompositionSolver()

        for scenario in try loadCorpus().scenarios {
            let weights = weights(for: scenario.weights)
            let result = try solver.solve(
                palette: scenario.palette.sorted { $0.index < $1.index }.map(color(for:)),
                sourceGrids: grids(for: scenario.target, weights: weights),
                weights: weights
            )

            if let expectedIndex = scenario.expected.selectedIndex {
                XCTAssertEqual(result.colorIndex(x: 0, y: 0), expectedIndex, scenario.id)
                XCTAssertEqual(result.palette[expectedIndex].hex, scenario.expected.selectedHexColor, scenario.id)
                XCTAssertEqual(result.error(x: 0, y: 0), scenario.expected.error, scenario.id)
                XCTAssertEqual(tiedIndices(in: scenario.expected.scores, error: scenario.expected.error!), scenario.expected.tiedIndices, scenario.id)
                XCTAssertEqual(scenario.expected.tieBroke, scenario.expected.tiedIndices.count > 1, scenario.id)
                XCTAssertEqual(scenario.expected.tiedIndices.first, expectedIndex, scenario.id)
            } else {
                XCTAssertNil(result.colorIndex(x: 0, y: 0), scenario.id)
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
                XCTAssertNil(scenario.expected.tieBroke, scenario.id)
                XCTAssertTrue(scenario.expected.tiedIndices.isEmpty, scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func color(for vector: ParityVector) -> PaletteColor {
        let responses = vector.channels.reduce(into: [LightingCondition: IlluminationResponse]()) { result, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            result[condition] = IlluminationResponse(brightness: entry.value)
        }
        return PaletteColor(id: vector.index ?? -1, hex: vector.hexColor, rgb: RGBColor(hex: vector.hexColor)!, responses: responses)
    }

    private func target(for vector: ParityVector) -> TargetResponseVector {
        TargetResponseVector(vector.channels.reduce(into: [:]) { result, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            result[condition] = entry.value
        })
    }

    private func weights(for encoded: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: encoded[LightingCondition.white.rawValue] ?? 0,
            red: encoded[LightingCondition.red.rawValue] ?? 0,
            green: encoded[LightingCondition.green.rawValue] ?? 0,
            blue: encoded[LightingCondition.blue.rawValue] ?? 0,
            lps: encoded[LightingCondition.lps.rawValue] ?? 0
        )
    }

    private func grids(for target: ParityVector, weights: ChannelWeights) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [target.channels[condition.rawValue] ?? 0]))
        })
    }

    private func assert(_ actual: ScorerResult, matches expected: ParityScore, scenarioID: String, index: Int) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, "\(scenarioID), candidate \(index)")
        default:
            XCTFail("\(scenarioID), candidate \(index): expected \(expected), got \(actual)")
        }
    }

    private func tiedIndices(in scores: [ParityExpectedScore], error: Double) -> [Int] {
        scores.compactMap {
            guard case .score(let score) = $0.score, score == error else { return nil }
            return $0.index
        }
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
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpectation
}

private struct ParityVector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpectation: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityExpectedScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable, CustomStringConvertible {
    case excluded
    case score(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let score = try? container.decode(Double.self) {
            self = .score(score)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .score(let score): return "\(score)"
        }
    }
}
