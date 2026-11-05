import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the canonical color_matching golden vectors. The fixture is copied
/// verbatim from `viamin/color_matching` so server/client solver drift is a
/// failing test rather than a documentation-only concern.
final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesVersionOneCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.scenarios.map(\.id), Self.versionOneScenarioIDs)

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = directory.appendingPathComponent("Fixtures/Parity/v1/corpus.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: url))
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let target = TargetResponseVector(responses(from: scenario.target.channels))
        let weights = weights(from: scenario.weights)
        let palette = try scenario.palette.map(makeColor)
        let scorer = WeightedSquaredErrorScorer()
        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
        for (actual, expected) in zip(actualScores, scenario.expected.scores) {
            switch (actual, expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .value(let expected)):
                XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario.id)
            default:
                XCTFail("\(scenario.id): score at index \(expected.index) diverged")
            }
        }

        guard let expectedIndex = scenario.expected.selectedIndex else {
            XCTAssertTrue(actualScores.allSatisfy { $0 == .excluded }, scenario.id)
            return
        }

        let sourceGrids = Dictionary(
            uniqueKeysWithValues: target.brightness.map { condition, value in
                (condition, BrightnessGrid(width: 1, height: 1, values: [value]))
            }
        )
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: sourceGrids,
            weights: weights
        )

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), expectedIndex, scenario.id)
        XCTAssertEqual(result.error(x: 0, y: 0), scenario.expected.error, accuracy: 1e-12, scenario.id)
        XCTAssertEqual(palette[expectedIndex].hex, scenario.expected.selectedHexColor, scenario.id)
        XCTAssertEqual(tiedIndices(in: actualScores), scenario.expected.tiedIndices, scenario.id)
    }

    private func makeColor(_ entry: ParityVector) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: entry.hexColor), "Invalid corpus hex \(entry.hexColor)")
        let responses = responses(from: entry.channels).mapValues { IlluminationResponse(brightness: $0) }
        return PaletteColor(id: entry.index, hex: entry.hexColor, rgb: rgb, responses: responses)
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func weights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func tiedIndices(in scores: [ScorerResult]) -> [Int] {
        guard let lowest = scores.compactMap({ result -> Double? in
            guard case .score(let value) = result else { return nil }
            return value
        }).min() else {
            return []
        }
        return scores.indices.filter { scores[$0] == .score(lowest) }
    }

    private static let versionOneScenarioIDs = [
        "distinct-errors", "tie-symmetric-around-target", "tie-duplicate-vectors",
        "tie-three-way-on-lps", "missing-candidate-excluded", "missing-target-excluded",
        "zero-weight-channel-missing", "all-excluded", "single-channel-lps",
        "exact-match-zero-error", "unknown-weight-ignored", "mixed-large-palette"
    ]
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
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
    let selectedIndex: Int?
    let selectedHexColor: String?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: Score

    enum Score: Decodable {
        case excluded
        case value(Double)

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
}
