import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let palette = try scenario.palette.map(makePaletteColor)
            let target = try makeTarget(scenario.target)
            let weights = try makeWeights(scenario.weights)

            for expectedScore in scenario.expected.scores {
                let result = scorer.score(
                    candidate: palette[expectedScore.index],
                    target: target,
                    weights: weights
                )
                assert(result, equals: expectedScore.score, scenario: scenario.id)
            }

            guard let selectedIndex = scenario.expected.selectedIndex,
                  let expectedError = scenario.expected.error
            else {
                XCTAssertNil(scenario.expected.selectedHexColor, scenario.id)
                XCTAssertNil(scenario.expected.tieBroke, scenario.id)
                XCTAssertTrue(scenario.expected.tiedIndices.isEmpty, scenario.id)
                continue
            }

            let tiedIndices = scenario.expected.scores.compactMap { score in
                score.score == expectedError ? score.index : nil
            }
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)

            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: try sourceGrids(for: scenario.target, weights: weights),
                weights: weights
            )
            XCTAssertEqual(result.colorIndex(x: 0, y: 0), selectedIndex, scenario.id)
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
            XCTAssertEqual(
                palette[try XCTUnwrap(result.colorIndex(x: 0, y: 0), scenario.id)].hex,
                scenario.expected.selectedHexColor,
                scenario.id
            )
            XCTAssertEqual(scenario.expected.tieBroke, tiedIndices.count > 1, scenario.id)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makePaletteColor(_ fixture: PaletteFixture) throws -> PaletteColor {
        let responses = try fixture.channels.reduce(into: [LightingCondition: IlluminationResponse]()) {
            responses, entry in
            responses[try condition(entry.key)] = IlluminationResponse(brightness: entry.value)
        }
        return PaletteColor(
            id: fixture.index,
            hex: fixture.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: fixture.hexColor)),
            responses: responses
        )
    }

    private func makeTarget(_ fixture: VectorFixture) throws -> TargetResponseVector {
        TargetResponseVector(try fixture.channels.reduce(into: [:]) { values, entry in
            values[try condition(entry.key)] = entry.value
        })
    }

    private func makeWeights(_ values: [String: Double]) throws -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0], red: values["red", default: 0],
            green: values["green", default: 0], blue: values["blue", default: 0],
            lps: values["lps", default: 0]
        )
    }

    private func sourceGrids(for target: VectorFixture, weights: ChannelWeights) throws -> [LightingCondition: BrightnessGrid] {
        try weights.activeConditions.reduce(into: [:]) { grids, condition in
            grids[condition] = BrightnessGrid(
                width: 1,
                height: 1,
                values: [try XCTUnwrap(target.channels[condition.rawValue])]
            )
        }
    }

    private func condition(_ rawValue: String) throws -> LightingCondition {
        try XCTUnwrap(LightingCondition(rawValue: rawValue), "Unknown corpus light source: \(rawValue)")
    }

    private func assert(_ result: ScorerResult, equals expected: Double?, scenario: String) {
        switch (result, expected) {
        case (.excluded, nil):
            break
        case (.score(let actual), .some(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario)
        default:
            XCTFail("Unexpected scorer result for \(scenario): \(result)")
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [PaletteFixture]
    let target: VectorFixture
    let weights: [String: Double]
    let expected: ExpectedFixture
}

private struct PaletteFixture: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int
}

private struct VectorFixture: Decodable {
    let channels: [String: Double]
}

private struct ExpectedFixture: Decodable {
    let error: Double?
    let scores: [ExpectedScoreFixture]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ExpectedScoreFixture: Decodable {
    let index: Int
    let score: Double?

    private enum CodingKeys: String, CodingKey {
        case index
        case score
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        score = try? container.decode(Double.self, forKey: .score)
    }
}
