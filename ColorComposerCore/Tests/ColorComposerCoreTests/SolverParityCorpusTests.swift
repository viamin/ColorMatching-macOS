import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesServerParityCorpus() throws {
        let corpus = try decodeCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let palette = scenario.palette.map(makeColor)
            let target = TargetResponseVector(responseVector(from: scenario.target.channels))
            let weights = makeWeights(scenario.weights)

            XCTAssertEqual(scenario.expected.scores.count, palette.count, scenario.id)
            for (candidate, expected) in zip(palette, scenario.expected.scores) {
                XCTAssertEqual(candidate.id, expected.index, scenario.id)
                XCTAssertEqual(
                    scorer.score(candidate: candidate, target: target, weights: weights),
                    expected.score.scorerResult,
                    "score mismatch for \(scenario.id), candidate \(candidate.id)"
                )
            }

            try assertSolverSelection(
                scenario: scenario,
                palette: palette,
                weights: weights
            )
        }
    }

    private func assertSolverSelection(
        scenario: Scenario,
        palette: [PaletteColor],
        weights: ChannelWeights
    ) throws {
        let targetResponses = responseVector(from: scenario.target.channels)
        guard weights.activeConditions.allSatisfy({ targetResponses[$0] != nil }) else {
            // A source grid always has a value, so this server scenario is only
            // representable through the scorer assertion above.
            return
        }

        let sourceGrids = Dictionary(uniqueKeysWithValues: weights.activeConditions.map {
            ($0, BrightnessGrid(width: 1, height: 1, values: [targetResponses[$0]!]))
        })
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: sourceGrids,
            weights: weights
        )

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
        if let expectedError = scenario.expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, scenario.id)
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
        }
    }

    private func decodeCorpus() throws -> Corpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Corpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makeColor(_ candidate: Candidate) -> PaletteColor {
        PaletteColor(
            id: candidate.index!,
            hex: candidate.hexColor,
            rgb: RGBColor(hex: candidate.hexColor)!,
            responses: responseVector(from: candidate.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func responseVector(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, value in
            LightingCondition(rawValue: name).map { ($0, value) }
        })
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
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let selection: String
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let palette: [Candidate]
    let target: Candidate
    let weights: [String: Double]
    let expected: Expected
}

private struct Candidate: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct Expected: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedIndex: Int?
}

private struct ExpectedScore: Decodable {
    let index: Int
    let score: CorpusScore
}

private enum CorpusScore: Decodable {
    case score(Double)
    case excluded

    var scorerResult: ScorerResult {
        switch self {
        case .score(let value): return .score(value)
        case .excluded: return .excluded
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let score = try? container.decode(Double.self) {
            self = .score(score)
            return
        }
        guard try container.decode(String.self) == "excluded" else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
        self = .excluded
    }
}
