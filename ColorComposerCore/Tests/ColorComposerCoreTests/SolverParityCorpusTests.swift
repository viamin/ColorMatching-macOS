import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedParityCorpus() throws {
        let corpus = try decodeCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let weights = makeWeights(scenario.weights)
            let target = TargetResponseVector(makeResponses(scenario.target.channels))
            let palette = try scenario.palette.map(makeColor)
            let expectedScores = scenario.expected.scores

            XCTAssertEqual(expectedScores.compactMap(\.index), Array(palette.indices), scenario.id)
            for (color, expected) in zip(palette, expectedScores) {
                XCTAssertEqual(
                    scorer.score(candidate: color, target: target, weights: weights),
                    expected.score.scorerResult,
                    "score mismatch for scenario \(scenario.id), candidate \(expected.index)"
                )
            }

            let tiedIndices = tiedBestIndices(expectedScores)
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)

            guard let expectedIndex = scenario.expected.selectedIndex else {
                XCTAssertNil(expectedScores.compactMap(\.score.numeric).min(), scenario.id)
                XCTAssertNil(scenario.expected.tieBroke, scenario.id)
                continue
            }

            XCTAssertEqual(scenario.expected.tieBroke, tiedIndices.count > 1, scenario.id)
            XCTAssertEqual(firstBestIndex(in: expectedScores), expectedIndex, scenario.id)
            XCTAssertEqual(palette[expectedIndex].hex, scenario.expected.selectedHexColor, scenario.id)
            XCTAssertEqual(expectedScores[expectedIndex].score.numeric, scenario.expected.error, scenario.id)

            guard weights.activeEntries.allSatisfy({ target.value(for: $0.condition) != nil }) else {
                continue
            }
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: sourceGrids(from: target, weights: weights),
                weights: weights
            )
            XCTAssertEqual(result.colorIndex(x: 0, y: 0), expectedIndex, scenario.id)
            XCTAssertEqual(
                result.error(x: 0, y: 0),
                try XCTUnwrap(scenario.expected.error),
                scenario.id
            )
        }
    }

    private func decodeCorpus() throws -> Corpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Corpus.self, from: Data(contentsOf: fixture))
    }

    private func makeWeights(_ values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0], red: values["red", default: 0],
            green: values["green", default: 0], blue: values["blue", default: 0],
            lps: values["lps", default: 0]
        )
    }

    private func makeResponses(_ channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, brightness) }
        })
    }

    private func makeColor(_ entry: Corpus.Entry) throws -> PaletteColor {
        PaletteColor(
            id: try XCTUnwrap(entry.index),
            hex: entry.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: entry.hexColor)),
            responses: makeResponses(entry.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func sourceGrids(
        from target: TargetResponseVector,
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeEntries.map { entry in
            (entry.condition, BrightnessGrid(width: 1, height: 1, values: [target.value(for: entry.condition)!]))
        })
    }

    private func firstBestIndex(in scores: [Corpus.Expected.Score]) -> Int? {
        guard let best = scores.compactMap(\.score.numeric).min() else { return nil }
        return scores.first(where: { $0.score.numeric == best })?.index
    }

    private func tiedBestIndices(_ scores: [Corpus.Expected.Score]) -> [Int] {
        guard let best = scores.compactMap(\.score.numeric).min() else { return [] }
        return scores.compactMap { $0.score.numeric == best ? $0.index : nil }
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [Scenario]

    struct Scenario: Decodable {
        let id: String
        let weights: [String: Double]
        let target: Entry
        let palette: [Entry]
        let expected: Expected
    }

    struct Entry: Decodable {
        let channels: [String: Double]
        let hexColor: String
        let index: Int?
    }

    struct Expected: Decodable {
        let error: Double?
        let scores: [Score]
        let selectedHexColor: String?
        let selectedIndex: Int?
        let tieBroke: Bool?
        let tiedIndices: [Int]

        struct Score: Decodable {
            let index: Int
            let score: ScoreValue
        }
    }
}

private enum ScoreValue: Decodable {
    case score(Double)
    case excluded

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

    var numeric: Double? {
        guard case .score(let value) = self else { return nil }
        return value
    }

    var scorerResult: ScorerResult {
        switch self {
        case .score(let value): return .score(value)
        case .excluded: return .excluded
        }
    }
}
