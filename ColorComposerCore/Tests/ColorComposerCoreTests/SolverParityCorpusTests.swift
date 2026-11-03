import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testCorpusMetadataDeclaresVersionOneWeightedSquaredErrorContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertFalse(corpus.scenarios.isEmpty)
    }

    func testWeightedSquaredErrorScorerAndSolverMatchEveryCorpusScenario() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let palette = try scenario.palette.map(makeColor)
            let target = makeTarget(scenario.target)
            let weights = makeWeights(scenario.weights)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
            for (actual, expected) in zip(actualScores, scenario.expected.scores) {
                assert(actual, matches: expected.score, scenarioID: scenario.id, paletteIndex: expected.index)
            }

            let tiedIndices = scenario.expected.error.map { error in
                scenario.expected.scores.compactMap { candidate in
                    candidate.score == error ? candidate.index : nil
                }
            } ?? []
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
            XCTAssertEqual(scenario.expected.tieBroke, tiedIndices.count > 1, scenario.id)

            guard let expectedIndex = scenario.expected.selectedIndex else {
                XCTAssertTrue(actualScores.allSatisfy(isExcluded), scenario.id)
                continue
            }
            let expectedError = try XCTUnwrap(scenario.expected.error)
            let expectedHexColor = try XCTUnwrap(scenario.expected.selectedHexColor)

            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: try sourceGrids(for: scenario.target, weights: weights),
                weights: weights
            )
            XCTAssertEqual(result.colorIndex(x: 0, y: 0), expectedIndex, scenario.id)
            XCTAssertEqual(result.palette[expectedIndex].hex, expectedHexColor, scenario.id)
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
        }
    }

    private func loadCorpus() throws -> SolverParityCorpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
        return try JSONDecoder().decode(SolverParityCorpus.self, from: Data(contentsOf: url))
    }

    private func makeColor(_ entry: SolverParityCorpus.Vector) throws -> PaletteColor {
        let responses = try entry.channels.reduce(into: [LightingCondition: IlluminationResponse]()) { responses, pair in
            let condition = try XCTUnwrap(LightingCondition(rawValue: pair.key))
            responses[condition] = IlluminationResponse(brightness: pair.value)
        }
        return PaletteColor(
            id: try XCTUnwrap(entry.index),
            hex: entry.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: entry.hexColor)),
            responses: responses
        )
    }

    private func makeTarget(_ entry: SolverParityCorpus.Vector) -> TargetResponseVector {
        TargetResponseVector(entry.channels.reduce(into: [:]) { values, pair in
            guard let condition = LightingCondition(rawValue: pair.key) else { return }
            values[condition] = pair.value
        })
    }

    private func makeWeights(_ values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0],
            red: values["red", default: 0],
            green: values["green", default: 0],
            blue: values["blue", default: 0],
            lps: values["lps", default: 0]
        )
    }

    private func sourceGrids(
        for target: SolverParityCorpus.Vector,
        weights: ChannelWeights
    ) throws -> [LightingCondition: BrightnessGrid] {
        try weights.activeConditions.reduce(into: [:]) { grids, condition in
            let value = try XCTUnwrap(target.channels[condition.rawValue])
            grids[condition] = BrightnessGrid(width: 1, height: 1, values: [value])
        }
    }

    private func assert(
        _ result: ScorerResult,
        matches expected: Double?,
        scenarioID: String,
        paletteIndex: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (result, expected) {
        case (.excluded, nil):
            break
        case (.score(let actual), .some(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "\(scenarioID), candidate \(paletteIndex)", file: file, line: line)
        default:
            XCTFail("\(scenarioID), candidate \(paletteIndex): expected \(String(describing: expected)), got \(result)", file: file, line: line)
        }
    }

    private func isExcluded(_ result: ScorerResult) -> Bool {
        if case .excluded = result { return true }
        return false
    }
}

private struct SolverParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scenarios: [Scenario]

    struct Scenario: Decodable {
        let id: String
        let weights: [String: Double]
        let target: Vector
        let palette: [Vector]
        let expected: Expected
    }

    struct Vector: Decodable {
        let channels: [String: Double]
        let hexColor: String
        let index: Int?
    }

    struct Expected: Decodable {
        let error: Double?
        let scores: [CandidateScore]
        let selectedHexColor: String?
        let selectedIndex: Int?
        let tieBroke: Bool
        let tiedIndices: [Int]
    }

    struct CandidateScore: Decodable {
        let index: Int
        let score: Double?

        private enum CodingKeys: String, CodingKey {
            case index
            case score
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            index = try container.decode(Int.self, forKey: .index)
            if let score = try? container.decode(Double.self, forKey: .score) {
                self.score = score
                return
            }
            let marker = try container.decode(String.self, forKey: .score)
            guard marker == "excluded" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .score,
                    in: container,
                    debugDescription: "Expected a numeric score or the excluded marker."
                )
            }
            self.score = nil
        }
    }
}
