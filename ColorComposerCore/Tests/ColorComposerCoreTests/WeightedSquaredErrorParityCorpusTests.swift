import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesVersionOneParityCorpusExactly() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            let palette = scenario.palette.map(makePaletteColor)
            let target = TargetResponseVector(makeChannels(scenario.target.channels))
            let weights = makeWeights(scenario.weights)
            let scorer = WeightedSquaredErrorScorer()

            for expectedScore in scenario.expected.scores {
                let result = scorer.score(
                    candidate: palette[expectedScore.index],
                    target: target,
                    weights: weights
                )
                assert(result, matches: expectedScore.score, scenario: scenario.id, index: expectedScore.index)
            }

            let selected = selectBest(palette: palette, target: target, weights: weights, scorer: scorer)
            XCTAssertEqual(selected?.index, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(selected.map { palette[$0.index].hex }, scenario.expected.selectedHexColor, scenario.id)
            XCTAssertEqual(selected?.score, scenario.expected.error, scenario.id)

            if scenario.expected.tieBroke == true {
                XCTAssertEqual(selected?.index, scenario.expected.tiedIndices.min(), scenario.id)
                XCTAssertGreaterThan(scenario.expected.tiedIndices.count, 1, scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> Corpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: fixture))
    }

    private func makePaletteColor(_ fixture: PaletteFixture) -> PaletteColor {
        PaletteColor(
            id: fixture.index!,
            hex: fixture.hexColor,
            rgb: RGBColor(hex: fixture.hexColor)!,
            responses: makeChannels(fixture.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func makeChannels(_ channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, brightness) }
        })
    }

    private func makeWeights(_ weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white"] ?? 0,
            red: weights["red"] ?? 0,
            green: weights["green"] ?? 0,
            blue: weights["blue"] ?? 0,
            lps: weights["lps"] ?? 0
        )
    }

    private func selectBest(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights,
        scorer: WeightedSquaredErrorScorer
    ) -> (index: Int, score: Double)? {
        var best: (index: Int, score: Double)?
        for (index, color) in palette.enumerated() {
            guard case .score(let score) = scorer.score(candidate: color, target: target, weights: weights) else {
                continue
            }
            if best == nil || score < best!.score {
                best = (index, score)
            }
        }
        return best
    }

    private func assert(_ result: ScorerResult, matches expected: Score, scenario: String, index: Int) {
        switch (result, expected) {
        case (.excluded, .excluded):
            return
        case (.score(let actual), .number(let expected)):
            XCTAssertEqual(actual, expected, "\\(scenario), candidate \\(index)")
        default:
            XCTFail("\\(scenario), candidate \\(index): expected \\(expected), got \\(result)")
        }
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
    let palette: [PaletteFixture]
    let target: PaletteFixture
    let weights: [String: Double]
    let expected: Expected
}

private struct PaletteFixture: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct Expected: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ExpectedScore: Decodable {
    let index: Int
    let score: Score
}

private enum Score: Decodable, CustomStringConvertible {
    case excluded
    case number(Double)

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .number(let value): return String(value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected score or excluded")
        }
    }
}
