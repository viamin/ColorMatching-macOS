import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testV1CorpusMatchesScoresAndSelections() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let palette = scenario.palette.map(makeColor)
            let target = makeTarget(scenario.target.channels)
            let weights = makeWeights(scenario.weights)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
            for (actual, expected) in zip(actualScores, scenario.expected.scores) {
                switch (actual, expected.score) {
                case (.excluded, .excluded):
                    break
                case (.score(let actual), .value(let expected)):
                    XCTAssertEqual(actual, expected, accuracy: 1e-12, "\\(scenario.id), candidate \\(expected.index)")
                default:
                    XCTFail("\\(scenario.id), candidate \\(expected.index): score/exclusion mismatch")
                }
            }

            let selectedIndex = select(actualScores)
            XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(selectedIndex.map { palette[$0].hex }, scenario.expected.selectedHexColor, scenario.id)

            guard let selectedIndex, let expectedError = scenario.expected.error else {
                XCTAssertNil(scenario.expected.error, scenario.id)
                continue
            }
            guard case .score(let actualError) = actualScores[selectedIndex] else {
                return XCTFail("\\(scenario.id): selected candidate was excluded")
            }
            XCTAssertEqual(actualError, expectedError, accuracy: 1e-12, scenario.id)
        }
    }

    func testV1CorpusMatchesCompositionSolverSelectionWhereTargetIsComplete() throws {
        let corpus = try loadCorpus()
        let solver = CompositionSolver()

        for scenario in corpus.scenarios where allPositiveWeightChannelsExist(in: scenario) {
            let result = try solver.solve(
                palette: scenario.palette.map(makeColor),
                sourceGrids: sourceGrids(for: scenario.target.channels, weights: scenario.weights),
                weights: makeWeights(scenario.weights)
            )

            XCTAssertEqual(result.colorIndices, [scenario.expected.selectedIndex], scenario.id)
            if let expectedError = scenario.expected.error {
                XCTAssertEqual(result.errors[0], expectedError, accuracy: 1e-12, scenario.id)
            } else {
                XCTAssertEqual(result.errors, [.infinity], scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }

    private func makeColor(_ candidate: ParityCandidate) -> PaletteColor {
        PaletteColor(
            id: candidate.index ?? -1,
            hex: candidate.hexColor,
            rgb: RGBColor(hex: candidate.hexColor)!,
            responses: candidate.channels.reduce(into: [:]) { responses, entry in
                guard let condition = LightingCondition(rawValue: entry.key) else { return }
                responses[condition] = IlluminationResponse(brightness: entry.value)
            }
        )
    }

    private func makeTarget(_ channels: [String: Double]) -> TargetResponseVector {
        TargetResponseVector(channels.reduce(into: [:]) { values, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            values[condition] = entry.value
        })
    }

    private func makeWeights(_ values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0], red: values["red", default: 0],
            green: values["green", default: 0], blue: values["blue", default: 0],
            lps: values["lps", default: 0]
        )
    }

    private func select(_ scores: [ScorerResult]) -> Int? {
        scores.enumerated().reduce(into: (index: Int?, error: Double.infinity)) { best, entry in
            guard case .score(let error) = entry.element, error < best.error else { return }
            best = (entry.offset, error)
        }.index
    }

    private func allPositiveWeightChannelsExist(in scenario: ParityScenario) -> Bool {
        scenario.weights.allSatisfy { name, weight in
            weight <= 0 || LightingCondition(rawValue: name) == nil || scenario.target.channels[name] != nil
        }
    }

    private func sourceGrids(for channels: [String: Double], weights: [String: Double]) -> [LightingCondition: BrightnessGrid] {
        weights.reduce(into: [:]) { grids, entry in
            guard entry.value > 0, let condition = LightingCondition(rawValue: entry.key) else { return }
            grids[condition] = BrightnessGrid(width: 1, height: 1, values: [channels[entry.key]!])
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scenarios: [ParityScenario]
    let scorer: String
    let selection: String
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityCandidate]
    let target: ParityCandidate
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityCandidate: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
}

private struct ParityScore: Decodable {
    enum Value: Decodable {
        case excluded
        case value(Double)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) { self = .value(value) }
            else if try container.decode(String.self) == "excluded" { self = .excluded }
            else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown parity score") }
        }
    }

    let index: Int
    let score: Value
}
