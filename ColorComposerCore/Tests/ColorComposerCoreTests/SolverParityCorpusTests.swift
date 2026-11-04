import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchVersionOneCorpus() throws {
        let corpus = try JSONDecoder().decode(Corpus.self, from: try Data(contentsOf: corpusURL))

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            let palette = try scenario.palette.map(makePaletteColor)
            let weights = scenario.weights.channelWeights
            let grids = try scenario.target.channels.mapValues { BrightnessGrid(width: 1, height: 1, values: [$0]) }
            let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)

            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(result.excludedCandidateCount, scenario.expected.scores.filter(\\.isExcluded).count, scenario.id)

            if let expectedError = scenario.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
            }
        }
    }

    private var corpusURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
    }

    private func makePaletteColor(_ vector: ColorVector) throws -> PaletteColor {
        let responses = try vector.channels.reduce(into: [LightingCondition: IlluminationResponse]()) { result, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            result[condition] = IlluminationResponse(brightness: entry.value)
        }
        return PaletteColor(
            id: try XCTUnwrap(vector.index),
            hex: vector.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: vector.hexColor)),
            responses: responses
        )
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let palette: [ColorVector]
    let target: ColorVector
    let weights: [String: Double]
    let expected: Expected
}

private struct ColorVector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct Expected: Decodable {
    let error: Double?
    let selectedIndex: Int?
    let scores: [ExpectedScore]
}

private struct ExpectedScore: Decodable {
    let score: Score

    var isExcluded: Bool {
        if case .excluded = score { return true }
        return false
    }
}

private enum Score: Decodable {
    case value(Double)
    case excluded

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
}

private extension Dictionary where Key == String, Value == Double {
    var channelWeights: ChannelWeights {
        ChannelWeights(
            white: self["white", default: 0],
            red: self["red", default: 0],
            green: self["green", default: 0],
            blue: self["blue", default: 0],
            lps: self["lps", default: 0]
        )
    }
}
