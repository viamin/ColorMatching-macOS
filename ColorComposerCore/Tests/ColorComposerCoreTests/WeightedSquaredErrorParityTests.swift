import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the corpus emitted by `viamin/color_matching` issue #111.
/// Refresh the fixture from the source repository, never by hand-editing cases.
final class WeightedSquaredErrorParityTests: XCTestCase {
    func testCorpusMetadataMatchesPublishedSolverContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertFalse(corpus.scenarios.isEmpty)
    }

    func testWeightedSquaredErrorScorerMatchesEveryPublishedCandidateScore() throws {
        let scorer = WeightedSquaredErrorScorer()

        for scenario in try loadCorpus().scenarios {
            let target = TargetResponseVector(channels(scenario.target.channels))
            let weights = makeWeights(scenario.weights)

            for candidate in scenario.palette {
                let actual = scorer.score(
                    candidate: makeColor(candidate),
                    target: target,
                    weights: weights
                )
                assert(actual, matches: scenario.expected.score(at: candidate.index), scenario: scenario.id)
            }
        }
    }

    func testSolverSelectionAndErrorMatchEveryPublishedScenarioIncludingTies() throws {
        for scenario in try loadCorpus().scenarios {
            let result = try CompositionSolver().solve(
                palette: scenario.palette.map(makeColor),
                sourceGrids: grids(for: scenario.target.channels),
                weights: makeWeights(scenario.weights)
            )

            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(
                result.colorIndex(x: 0, y: 0).map { scenario.palette[$0].hexColor },
                scenario.expected.selectedHexColor,
                scenario.id
            )
            if let expectedError = scenario.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> Corpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: fixture))
    }

    private func makeColor(_ candidate: Corpus.Candidate) -> PaletteColor {
        PaletteColor(
            id: candidate.index,
            hex: candidate.hexColor,
            rgb: RGBColor(hex: candidate.hexColor)!,
            responses: channels(candidate.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func channels(_ values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func grids(for values: [String: Double]) -> [LightingCondition: BrightnessGrid] {
        channels(values).mapValues { BrightnessGrid(width: 1, height: 1, values: [$0]) }
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

    private func assert(_ actual: ScorerResult, matches expected: Corpus.Score, scenario: String) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case let (.score(actual), .value(expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario)
        default:
            XCTFail("\\(scenario): expected \\(expected), got \\(actual)")
        }
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let scenarios: [Scenario]

    struct Scenario: Decodable {
        let id: String
        let palette: [Candidate]
        let target: Vector
        let weights: [String: Double]
        let expected: Expected
    }

    struct Vector: Decodable {
        let channels: [String: Double]
        let hexColor: String
    }

    struct Candidate: Decodable {
        let channels: [String: Double]
        let hexColor: String
        let index: Int
    }

    struct Expected: Decodable {
        let error: Double?
        let scores: [ExpectedScore]
        let selectedHexColor: String?
        let selectedIndex: Int?

        func score(at index: Int) -> Score {
            scores.first(where: { $0.index == index })!.score
        }
    }

    struct ExpectedScore: Decodable {
        let index: Int
        let score: Score
    }

    enum Score: Decodable, CustomStringConvertible {
        case excluded
        case value(Double)

        var description: String {
            switch self {
            case .excluded: return "excluded"
            case .value(let value): return String(value)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                self = .value(value)
            } else {
                guard try container.decode(String.self) == "excluded" else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an excluded score")
                }
                self = .excluded
            }
        }
    }
}
