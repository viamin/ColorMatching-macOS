import Foundation
import XCTest
@testable import ColorComposerCore

/// Golden vectors vendored from `viamin/color_matching` issue #111.
final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesParityCorpus() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let corpus = try decoder.decode(Corpus.self, from: try Data(contentsOf: corpusURL))
        XCTAssertEqual(corpus.algorithmVersion, 1)

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = TargetResponseVector(responses(scenario.target.channels))
            let weights = channelWeights(scenario.weights)
            let scores = scenario.palette.map { paletteColor in
                scorer.score(candidate: color(paletteColor), target: target, weights: weights)
            }

            for (actual, expected) in zip(scores, scenario.expected.scores) {
                switch (actual, expected.score) {
                case (.excluded, .excluded):
                    break
                case (.score(let actual), .value(let expected)):
                    XCTAssertEqual(actual, expected, accuracy: 1e-12, "scenario: \(scenario.id), candidate: \(expected.index)")
                default:
                    XCTFail("scenario: \(scenario.id), candidate: \(expected.index)")
                }
            }

            let result = try CompositionSolver().solve(
                palette: scenario.palette.map(color),
                sourceGrids: sourceGrids(target.channels, weights: weights),
                weights: weights
            )
            XCTAssertEqual(result.colorIndices.first, scenario.expected.selectedIndex, "scenario: \(scenario.id)")
            if let error = scenario.expected.error {
                XCTAssertEqual(result.errors.first, error, accuracy: 1e-12, "scenario: \(scenario.id)")
            } else {
                XCTAssertTrue(result.errors.first?.isInfinite == true, "scenario: \(scenario.id)")
            }

            let tied = scenario.expected.scores.compactMap { score in
                score.score.value == scenario.expected.error ? score.index : nil
            }
            XCTAssertEqual(tied, scenario.expected.tiedIndices, "scenario: \(scenario.id)")
        }
    }

    private var corpusURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
    }

    private func responses(_ channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func color(_ fixture: PaletteFixture) -> PaletteColor {
        PaletteColor(
            id: fixture.index,
            hex: fixture.hexColor,
            rgb: RGBColor(hex: fixture.hexColor)!,
            responses: responses(fixture.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func channelWeights(_ weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white", default: 0], red: weights["red", default: 0],
            green: weights["green", default: 0], blue: weights["blue", default: 0],
            lps: weights["lps", default: 0]
        )
    }

    private func sourceGrids(_ channels: [String: Double], weights: ChannelWeights) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [channels[condition.rawValue, default: 0]]))
        })
    }
}

private struct Corpus: Decodable { let algorithmVersion: Int; let scenarios: [Scenario] }
private struct Scenario: Decodable { let id: String; let palette: [PaletteFixture]; let target: PaletteFixture; let weights: [String: Double]; let expected: Expected }
private struct PaletteFixture: Decodable { let index: Int; let hexColor: String; let channels: [String: Double] }
private struct Expected: Decodable { let error: Double?; let scores: [ExpectedScore]; let selectedIndex: Int?; let tiedIndices: [Int] }
private struct ExpectedScore: Decodable { let index: Int; let score: CorpusScore }
private enum CorpusScore: Decodable {
    case value(Double); case excluded
    var value: Double? { if case .value(let value) = self { return value }; return nil }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) { self = .value(value) } else { self = .excluded }
    }
}
