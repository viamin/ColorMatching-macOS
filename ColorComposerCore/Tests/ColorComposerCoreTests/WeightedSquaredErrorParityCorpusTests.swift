import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testCorpusVersionAndSourceContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
    }

    func testWeightedSquaredErrorMatchesCommittedParityCorpus() throws {
        let scorer = WeightedSquaredErrorScorer()

        for scenario in try loadCorpus().scenarios {
            let target = targetVector(from: scenario.target.channels)
            let weights = weights(from: scenario.weights)
            let palette = scenario.palette.map(color(from:))
            let scored = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(scored.count, scenario.expected.scores.count, scenario.id)
            for (actual, expected) in zip(scored, scenario.expected.scores) {
                assert(actual, matches: expected.score, scenarioID: scenario.id, candidateIndex: expected.index)
            }

            let expectedSelection = scenario.expected.selectedIndex
            let selected = earliestLowestScore(in: scored)
            XCTAssertEqual(selected, expectedSelection, scenario.id)

            if let expectedSelection {
                XCTAssertEqual(palette[expectedSelection].hex, scenario.expected.selectedHexColor, scenario.id)
                guard case .score(let expectedError) = scenario.expected.scores[expectedSelection].score,
                      case .score(let actualError) = scored[expectedSelection]
                else {
                    return XCTFail("Expected a selected score for \(scenario.id)")
                }
                XCTAssertEqual(actualError, expectedError, accuracy: 1e-12, scenario.id)
            }

            XCTAssertEqual(
                scenario.expected.tiedIndices,
                tiedIndices(in: scored, expectedError: scenario.expected.error),
                scenario.id
            )
        }
    }

    func testCompositionSolverMatchesCorpusSelectionsWhenTargetsAreComplete() throws {
        for scenario in try loadCorpus().scenarios where completeTarget(scenario) {
            let weights = weights(from: scenario.weights)
            let sourceGrids = Dictionary(
                uniqueKeysWithValues: weights.activeEntries.map { condition, _ in
                    (condition, BrightnessGrid(width: 1, height: 1, values: [scenario.target.channels[condition.rawValue]!]))
                }
            )

            let result = try CompositionSolver().solve(
                palette: scenario.palette.map(color(from:)),
                sourceGrids: sourceGrids,
                weights: weights
            )

            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
            if let expectedError = scenario.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory.appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func color(from fixture: ParityColor) -> PaletteColor {
        let responses = fixture.channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, IlluminationResponse(brightness: value)) }
        }
        return PaletteColor(
            id: fixture.index ?? -1,
            hex: fixture.hexColor,
            rgb: RGBColor(hex: fixture.hexColor)!,
            responses: Dictionary(uniqueKeysWithValues: responses)
        )
    }

    private func targetVector(from channels: [String: Double]) -> TargetResponseVector {
        TargetResponseVector(Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        }))
    }

    private func weights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func completeTarget(_ scenario: ParityScenario) -> Bool {
        weights(from: scenario.weights).activeEntries.allSatisfy { condition, _ in
            scenario.target.channels[condition.rawValue] != nil
        }
    }

    private func earliestLowestScore(in scores: [ScorerResult]) -> Int? {
        var best: (index: Int, value: Double)?
        for (index, result) in scores.enumerated() {
            guard case .score(let value) = result else { continue }
            if best == nil || value < best!.value { best = (index, value) }
        }
        return best?.index
    }

    private func tiedIndices(in scores: [ScorerResult], expectedError: Double?) -> [Int] {
        guard let expectedError else { return [] }
        return scores.enumerated().compactMap { index, result in
            guard case .score(let value) = result, value == expectedError else { return nil }
            return index
        }
    }

    private func assert(
        _ actual: ScorerResult,
        matches expected: ParityScore,
        scenarioID: String,
        candidateIndex: Int
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .value(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "\(scenarioID), candidate \(candidateIndex)")
        default:
            XCTFail("\(scenarioID), candidate \(candidateIndex): expected \(expected), received \(actual)")
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [ParityScenario]
    let scorer: String
    let selection: String
}

private struct ParityScenario: Decodable {
    let expected: ParityExpected
    let id: String
    let palette: [ParityColor]
    let target: ParityColor
    let weights: [String: Double]
}

private struct ParityColor: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tiedIndices: [Int]
}

private struct ParityExpectedScore: Decodable {
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
