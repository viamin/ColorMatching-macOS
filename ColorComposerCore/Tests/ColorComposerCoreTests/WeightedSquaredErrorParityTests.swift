import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testVersionOneCorpusMatchesScoresAndSelectionsExactly() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)

        for scenario in corpus.scenarios {
            let palette = scenario.palette.map(makePaletteColor)
            let target = TargetResponseVector(channelValues(from: scenario.target.channels))
            let weights = makeWeights(scenario.weights)
            let scorer = WeightedSquaredErrorScorer()

            for expectedScore in scenario.expected.scores {
                let actual = scorer.score(
                    candidate: palette[expectedScore.index], target: target, weights: weights
                )
                assert(actual, equals: expectedScore.score, scenario: scenario.id, index: expectedScore.index)
            }

            let selection = select(palette: palette, target: target, weights: weights)
            XCTAssertEqual(selection.index, scenario.expected.selectedIndex, "scenario \(scenario.id)")
            XCTAssertEqual(selection.error, scenario.expected.error, "scenario \(scenario.id)")
            XCTAssertEqual(
                selection.index.map { palette[$0].hex }, scenario.expected.selectedHexColor,
                "scenario \(scenario.id)"
            )

            if scenario.expected.error != nil {
                let result = try CompositionSolver().solve(
                    palette: palette,
                    sourceGrids: sourceGrids(from: scenario.target.channels, weights: weights),
                    weights: weights
                )
                XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, "scenario \(scenario.id)")
                XCTAssertEqual(result.error(x: 0, y: 0), scenario.expected.error, "scenario \(scenario.id)")
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makePaletteColor(_ fixture: ParityPaletteColor) -> PaletteColor {
        PaletteColor(
            id: fixture.index,
            hex: fixture.hexColor,
            rgb: RGBColor(hex: fixture.hexColor)!,
            responses: channelValues(from: fixture.channels)
                .mapValues { IlluminationResponse(brightness: $0) }
        )
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

    private func channelValues(from values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { name, value in
            LightingCondition(rawValue: name).map { ($0, value) }
        })
    }

    private func sourceGrids(
        from values: [String: Double], weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [values[condition.rawValue, default: 0]]))
        })
    }

    private func select(
        palette: [PaletteColor], target: TargetResponseVector, weights: ChannelWeights
    ) -> (index: Int?, error: Double?) {
        let scorer = WeightedSquaredErrorScorer()
        var selected: (index: Int, error: Double)?

        for (index, candidate) in palette.enumerated() {
            guard case .score(let error) = scorer.score(candidate: candidate, target: target, weights: weights) else {
                continue
            }
            if selected == nil || error < selected!.error {
                selected = (index, error)
            }
        }
        return (selected?.index, selected?.error)
    }

    private func assert(_ actual: ScorerResult, equals expected: ExpectedScore, scenario: String, index: Int) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, "scenario \(scenario), candidate \(index)")
        default:
            XCTFail("scenario \(scenario), candidate \(index): expected \(expected), received \(actual)")
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityPaletteColor]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityPaletteColor: Decodable {
    let index: Int
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityVector: Decodable {
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
    let score: ExpectedScore
}

private enum ExpectedScore: Decodable, CustomStringConvertible {
    case excluded
    case score(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .score(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown score value")
        }
    }

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .score(let value): return "score(\(value))"
        }
    }
}
