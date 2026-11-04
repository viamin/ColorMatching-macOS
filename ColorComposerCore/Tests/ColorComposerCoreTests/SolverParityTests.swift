import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedV1ParityCorpus() throws {
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
        let palette = try scenario.palette.map(makePaletteColor)
        let target = TargetResponseVector(responses(from: scenario.target.channels))
        let weights = channelWeights(from: scenario.weights)
        let scorer = WeightedSquaredErrorScorer()

        for expectedScore in scenario.expected.scores {
            let score = scorer.score(
                candidate: palette[expectedScore.index],
                target: target,
                weights: weights
            )
            assert(score, equals: expectedScore.score, scenarioID: scenario.id, candidateIndex: expectedScore.index)
        }

        let selected = earliestBestCandidate(in: palette, target: target, weights: weights)
        XCTAssertEqual(selected?.index, scenario.expected.selectedIndex, "scenario: \(scenario.id)")
        if let expectedError = scenario.expected.error {
            let actual = try XCTUnwrap(selected, "scenario: \(scenario.id)")
            XCTAssertEqual(actual.score, expectedError, accuracy: 1e-12, "scenario: \(scenario.id)")
        } else {
            XCTAssertNil(selected, "scenario: \(scenario.id)")
        }
        let tiedIndices = scenario.expected.scores.compactMap { candidate -> Int? in
            guard let expectedError = scenario.expected.error,
                  case .value(let score) = candidate.score,
                  score == expectedError
            else { return nil }
            return candidate.index
        }
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, "scenario: \(scenario.id)")
        XCTAssertEqual(selected == nil ? nil : tiedIndices.count > 1, scenario.expected.tieBroke, "scenario: \(scenario.id)")

        guard weights.activeConditions.allSatisfy({ target.value(for: $0) != nil }) else {
            return
        }

        let sourceGrids = Dictionary(
            uniqueKeysWithValues: weights.activeConditions.map { condition in
                (condition, BrightnessGrid(width: 1, height: 1, values: [target.value(for: condition) ?? 0]))
            }
        )
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: sourceGrids, weights: weights)

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, "scenario: \(scenario.id)")
        XCTAssertEqual(result.error(x: 0, y: 0), scenario.expected.error ?? .infinity, accuracy: 1e-12, "scenario: \(scenario.id)")
        if let selectedIndex = scenario.expected.selectedIndex {
            XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor, "scenario: \(scenario.id)")
        }
        XCTAssertEqual(
            scenario.expected.tiedIndices.first,
            scenario.expected.selectedIndex,
            "scenario: \(scenario.id) must select the earliest tied candidate"
        )
    }

    private func earliestBestCandidate(
        in palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> (index: Int, score: Double)? {
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
        return best
    }

    private func assert(
        _ actual: ScorerResult,
        equals expected: ParityScore,
        scenarioID: String,
        candidateIndex: Int
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .value(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "scenario: \(scenarioID), candidate: \(candidateIndex)")
        default:
            XCTFail("scenario: \(scenarioID), candidate: \(candidateIndex), expected \(expected)")
        }
    }

    private func makePaletteColor(_ fixture: ParityColor) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: fixture.hexColor), "Invalid corpus hex color: \(fixture.hexColor)")
        return PaletteColor(
            id: try XCTUnwrap(fixture.index, "Palette entry is missing an index"),
            hex: fixture.hexColor,
            rgb: rgb,
            responses: responses(from: fixture.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            guard let condition = LightingCondition(rawValue: name) else { return nil }
            return (condition, brightness)
        })
    }

    private func channelWeights(from weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white"] ?? 0,
            red: weights["red"] ?? 0,
            green: weights["green"] ?? 0,
            blue: weights["blue"] ?? 0,
            lps: weights["lps"] ?? 0
        )
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityColor]
    let target: ParityColor
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityColor: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
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
