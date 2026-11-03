import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testMatchesCommittedColorMatchingParityCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let weights = ChannelWeights(channels: scenario.weights)
        let target = TargetResponseVector(scenario.target.channels.lightingValues)
        let palette = try scenario.palette.map(makePaletteColor)
        let scorer = WeightedSquaredErrorScorer()

        for expectedScore in scenario.expected.scores {
            let result = scorer.score(
                candidate: palette[expectedScore.index],
                target: target,
                weights: weights
            )
            assert(result, matches: expectedScore.score, scenario: scenario.id, index: expectedScore.index)
        }

        let selection = select(palette: palette, target: target, weights: weights, scorer: scorer)
        XCTAssertEqual(selection.index, scenario.expected.selectedIndex, scenario.id)
        assert(selection.error, matches: scenario.expected.error, scenario: scenario.id)
        XCTAssertEqual(
            selection.index.map { palette[$0].hex },
            scenario.expected.selectedHexColor,
            scenario.id
        )
        if scenario.expected.tieBroke == true {
            XCTAssertEqual(selection.index, scenario.expected.tiedIndices.first, scenario.id)
        }

        guard weights.activeConditions.allSatisfy({ target.value(for: $0) != nil }) else {
            return
        }
        let sourceGrids = scenario.target.channels.lightingValues.mapValues {
            BrightnessGrid(width: 1, height: 1, values: [$0])
        }
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: sourceGrids,
            weights: weights
        )

        XCTAssertEqual(result.colorIndices, [scenario.expected.selectedIndex], scenario.id)
        if let expectedError = scenario.expected.error {
            guard let actualError = result.errors.first else {
                return XCTFail("\(scenario.id): expected a solver error")
            }
            XCTAssertEqual(actualError, expectedError, accuracy: 1e-12, scenario.id)
        } else {
            XCTAssertEqual(result.errors.first, .infinity, scenario.id)
        }
        XCTAssertEqual(
            (result.colorIndices.first ?? nil).map { result.palette[$0].hex },
            scenario.expected.selectedHexColor,
            scenario.id
        )
    }

    private func select(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights,
        scorer: WeightedSquaredErrorScorer
    ) -> (index: Int?, error: Double?) {
        var best: (index: Int?, error: Double?) = (nil, nil)
        for (index, candidate) in palette.enumerated() {
            guard case .score(let score) = scorer.score(candidate: candidate, target: target, weights: weights),
                  best.error == nil || score < best.error!
            else {
                continue
            }
            best = (index, score)
        }
        return best
    }

    private func assert(
        _ result: ScorerResult,
        matches expected: ParityScore,
        scenario: String,
        index: Int
    ) {
        switch (result, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "\(scenario), palette index \(index)")
        default:
            XCTFail("\(scenario), palette index \(index): expected \(expected), got \(result)")
        }
    }

    private func assert(_ actual: Double?, matches expected: Double?, scenario: String) {
        switch (actual, expected) {
        case let (.some(actual), .some(expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario)
        case (nil, nil):
            break
        default:
            XCTFail("\(scenario): expected \(String(describing: expected)), got \(String(describing: actual))")
        }
    }

    private func makePaletteColor(_ fixture: ParityColor) throws -> PaletteColor {
        let responses = fixture.channels.lightingValues.mapValues(IlluminationResponse.init(brightness:))
        guard let rgb = RGBColor(hex: fixture.hexColor) else {
            throw ParityCorpusError.invalidHex(fixture.hexColor)
        }
        return PaletteColor(id: fixture.index ?? -1, hex: fixture.hexColor, rgb: rgb, responses: responses)
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }
}

private enum ParityCorpusError: Error {
    case invalidHex(String)
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
        if let value = try? container.decode(Double.self) {
            self = .score(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected score or excluded")
        }
    }

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .score(let value): return "\(value)"
        }
    }
}

private extension Dictionary where Key == String, Value == Double {
    var lightingValues: [LightingCondition: Double] {
        reduce(into: [:]) { values, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            values[condition] = entry.value
        }
    }
}

private extension ChannelWeights {
    init(channels: [String: Double]) {
        self.init(
            white: channels["white", default: 0],
            red: channels["red", default: 0],
            green: channels["green", default: 0],
            blue: channels["blue", default: 0],
            lps: channels["lps", default: 0]
        )
    }
}
