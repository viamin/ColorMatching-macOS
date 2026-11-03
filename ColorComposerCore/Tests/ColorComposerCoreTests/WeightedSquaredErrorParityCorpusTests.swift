import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = responseVector(scenario.target)
            let weights = weights(from: scenario.weights)
            let results = scenario.palette.map { candidate in
                scorer.score(candidate: paletteColor(candidate), target: target, weights: weights)
            }

            XCTAssertEqual(results, scenario.expected.scores.map(ScorerResult.init), scenario.id)

            let active = weights.activeConditions
            guard active.allSatisfy({ target.value(for: $0) != nil }) else {
                XCTAssertNil(scenario.expected.selectedIndex, scenario.id)
                continue
            }

            let grids = Dictionary(uniqueKeysWithValues: active.map { condition in
                (condition, BrightnessGrid(width: 1, height: 1, values: [target.value(for: condition)!]))
            })
            let solved = try CompositionSolver().solve(
                palette: scenario.palette.map(paletteColor), sourceGrids: grids, weights: weights
            )

            XCTAssertEqual(solved.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
            if let selectedIndex = scenario.expected.selectedIndex, let expectedError = scenario.expected.error {
                XCTAssertEqual(solved.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
                XCTAssertEqual(scenario.palette[selectedIndex].hexColor, scenario.expected.selectedHexColor, scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixture = testFile.deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func responseVector(_ vector: ParityVector) -> TargetResponseVector {
        TargetResponseVector(Dictionary(uniqueKeysWithValues: vector.channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        }))
    }

    private func paletteColor(_ vector: ParityVector) -> PaletteColor {
        let responses = Dictionary(uniqueKeysWithValues: vector.channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, IlluminationResponse(brightness: value)) }
        })
        return PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: responses
        )
    }

    private func weights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0], red: values["red", default: 0],
            green: values["green", default: 0], blue: values["blue", default: 0],
            lps: values["lps", default: 0]
        )
    }

}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let selection: String
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
    let scores: [ParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ParityScoreValue

    func asScorerResult() -> ScorerResult {
        switch score {
        case .value(let value): return .score(value)
        case .excluded: return .excluded
        }
    }
}

private enum ParityScoreValue: Decodable {
    case value(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown parity score")
        }
    }
}

private extension ScorerResult {
    init(_ parityScore: ParityScore) {
        self = parityScore.asScorerResult()
    }
}
