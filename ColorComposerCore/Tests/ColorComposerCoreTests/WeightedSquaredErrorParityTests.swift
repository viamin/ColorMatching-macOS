import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedV1ParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = TargetResponseVector(responses(from: scenario.target.channels))
            let palette = scenario.palette.map(makeColor)
            let weights = makeWeights(scenario.weights)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(actualScores, scenario.expected.scores.map(\\.result), scenario.id)

            let selection = selectEarliestLowestScore(from: actualScores)
            XCTAssertEqual(selection.index, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(selection.error, scenario.expected.error, scenario.id)
            XCTAssertEqual(
                selection.index.map { palette[$0].hex },
                scenario.expected.selectedHexColor,
                scenario.id
            )
            XCTAssertEqual(selection.tiedIndices, scenario.expected.tiedIndices, scenario.id)
            XCTAssertEqual(selection.tiedIndices.count > 1, scenario.expected.tieBroke ?? false, scenario.id)
        }
    }

    private func loadCorpus() throws -> Corpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: fixture))
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, value in
            LightingCondition(rawValue: name).map { ($0, value) }
        })
    }

    private func makeColor(_ entry: Corpus.Vector) -> PaletteColor {
        let responses = responses(from: entry.channels).mapValues(IlluminationResponse.init(brightness:))
        return PaletteColor(
            id: entry.index!,
            hex: entry.hexColor,
            rgb: RGBColor(hex: entry.hexColor)!,
            responses: responses
        )
    }

    private func makeWeights(_ weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights[LightingCondition.white.rawValue] ?? 0,
            red: weights[LightingCondition.red.rawValue] ?? 0,
            green: weights[LightingCondition.green.rawValue] ?? 0,
            blue: weights[LightingCondition.blue.rawValue] ?? 0,
            lps: weights[LightingCondition.lps.rawValue] ?? 0
        )
    }

    private func selectEarliestLowestScore(from scores: [ScorerResult]) -> Selection {
        let ranked = scores.enumerated().compactMap { index, result -> (Int, Double)? in
            guard case .score(let score) = result else { return nil }
            return (index, score)
        }
        guard let best = ranked.min(by: { $0.1 < $1.1 }) else {
            return Selection(index: nil, error: nil, tiedIndices: [])
        }
        return Selection(
            index: best.0,
            error: best.1,
            tiedIndices: ranked.filter { $0.1 == best.1 }.map(\\.0)
        )
    }
}

private extension WeightedSquaredErrorParityTests {
    struct Selection {
        let index: Int?
        let error: Double?
        let tiedIndices: [Int]
    }

    struct Corpus: Decodable {
        let algorithmVersion: Int
        let scorer: String
        let selection: String
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
            let index: Int?
            let hexColor: String
            let channels: [String: Double]
        }

        struct Expected: Decodable {
            let error: Double?
            let scores: [Score]
            let selectedHexColor: String?
            let selectedIndex: Int?
            let tieBroke: Bool?
            let tiedIndices: [Int]
        }

        struct Score: Decodable {
            let index: Int
            let result: ScorerResult

            private enum CodingKeys: String, CodingKey {
                case index
                case score
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                index = try container.decode(Int.self, forKey: .index)
                if let score = try? container.decode(Double.self, forKey: .score) {
                    result = .score(score)
                } else {
                    guard try container.decode(String.self, forKey: .score) == "excluded" else {
                        throw DecodingError.dataCorruptedError(
                            forKey: .score,
                            in: container,
                            debugDescription: "Expected a numeric score or excluded"
                        )
                    }
                    result = .excluded
                }
            }
        }
    }
}
