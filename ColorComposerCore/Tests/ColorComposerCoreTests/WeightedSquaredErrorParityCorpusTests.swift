import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testVersionOneCorpusMatchesScoresExclusionsAndSelections() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            let palette = scenario.palette.map(makePaletteColor)
            let weights = makeWeights(scenario.weights)
            let target = TargetResponseVector(makeChannels(scenario.target.channels))

            for (candidate, expected) in zip(palette, scenario.expected.scores) {
                XCTAssertEqual(candidate.id, expected.index, scenario.id)
                assertScore(
                    WeightedSquaredErrorScorer().score(candidate: candidate, target: target, weights: weights),
                    equals: expected.score,
                    scenario: scenario.id,
                    candidate: candidate.id
                )
            }

            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids(from: scenario.target.channels, weights: weights),
                weights: weights
            )
            XCTAssertEqual(result.colorIndices, [scenario.expected.selectedIndex], scenario.id)
            assertOptionalScore(result.errors[0], equals: scenario.expected.error, scenario: scenario.id)
            XCTAssertEqual(
                result.colorIndices[0].map { palette[$0].hex },
                scenario.expected.selectedHexColor,
                scenario.id
            )
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: file))
    }

    private func makePaletteColor(_ candidate: ParityCandidate) -> PaletteColor {
        PaletteColor(
            id: candidate.index,
            hex: candidate.hex,
            rgb: RGBColor(hex: candidate.hex)!,
            responses: makeChannels(candidate.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func makeChannels(_ values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func makeWeights(_ values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func sourceGrids(
        from target: [String: Double],
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, fill: target[condition.rawValue] ?? 0))
        })
    }

    private func assertScore(
        _ actual: ScorerResult,
        equals expected: ParityScore,
        scenario: String,
        candidate: Int
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let value), .score(let expected)):
            XCTAssertEqual(value, expected, accuracy: 1e-12, "\(scenario), candidate \(candidate)")
        default:
            XCTFail("\(scenario), candidate \(candidate): expected \(expected), got \(actual)")
        }
    }

    private func assertOptionalScore(_ actual: Double, equals expected: Double?, scenario: String) {
        guard let expected else {
            XCTAssertFalse(actual.isFinite, scenario)
            return
        }
        XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario)
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case scorer, selection, scenarios
    }
}

private struct ParityScenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: ParityVector
    let palette: [ParityCandidate]
    let expected: ParityExpected
}

private struct ParityCandidate: Decodable {
    let index: Int
    let hex: String
    let channels: [String: Double]

    enum CodingKeys: String, CodingKey {
        case index, channels
        case hex = "hex_color"
    }
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let selectedIndex: Int?
    let selectedHexColor: String?
    let error: Double?
    let scores: [ParityExpectedScore]

    enum CodingKeys: String, CodingKey {
        case selectedIndex = "selected_index"
        case selectedHexColor = "selected_hex_color"
        case error, scores
    }
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
        if let score = try? container.decode(Double.self) {
            self = .score(score)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .score(let score): return String(score)
        }
    }
}
