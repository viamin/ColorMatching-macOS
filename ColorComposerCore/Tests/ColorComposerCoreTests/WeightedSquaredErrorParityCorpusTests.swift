import Foundation
import XCTest
@testable import ColorComposerCore

/// Contracts the Swift scorer and selection policy against the corpus generated
/// by `color_matching`'s `ColorMatching.WeightedSquaredError` implementation.
final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesVersionOneCorpus() throws {
        let corpus = try JSONDecoder().decode(ParityCorpus.self, from: try Data(contentsOf: corpusURL()))
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")

        for scenario in corpus.scenarios {
            try assertScorerParity(for: scenario)
            try assertSelectionParity(for: scenario)
        }
    }

    private func assertScorerParity(for scenario: ParityScenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let target = TargetResponseVector(channels(from: scenario.target.channels))
        let weights = makeWeights(scenario.weights)

        for expected in scenario.expected.scores {
            let candidate = makeColor(scenario.palette[expected.index])
            switch (scorer.score(candidate: candidate, target: target, weights: weights), expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .value(let value)):
                XCTAssertEqual(actual, value, accuracy: 1e-12, "scenario: \(scenario.id), candidate: \(expected.index)")
            default:
                XCTFail("score mismatch in scenario: \(scenario.id), candidate: \(expected.index)")
            }
        }
    }

    private func assertSelectionParity(for scenario: ParityScenario) throws {
        let weights = makeWeights(scenario.weights)
        let activeConditions = weights.activeConditions
        guard activeConditions.allSatisfy({ scenario.target.channels[$0.rawValue] != nil }) else {
            // A source grid necessarily supplies every active target channel. The
            // scorer assertion above is the applicable contract for this corpus case.
            XCTAssertNil(scenario.expected.selectedIndex, "scenario: \(scenario.id)")
            return
        }

        let grids = Dictionary(uniqueKeysWithValues: activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [scenario.target.channels[condition.rawValue]!]))
        })
        let result = try CompositionSolver().solve(
            palette: scenario.palette.map(makeColor),
            sourceGrids: grids,
            weights: weights
        )

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, "scenario: \(scenario.id)")
        XCTAssertEqual(result.excludedCandidateCount, scenario.expected.scores.filter { $0.score == .excluded }.count, "scenario: \(scenario.id)")

        if let expectedError = scenario.expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, "scenario: \(scenario.id)")
            XCTAssertEqual(scenario.expected.tiedIndices.first, scenario.expected.selectedIndex, "tie policy must select the earliest candidate")
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, "scenario: \(scenario.id)")
            XCTAssertNil(result.colorIndex(x: 0, y: 0), "scenario: \(scenario.id)")
        }
    }

    private func corpusURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
    }

    private func makeColor(_ fixture: ParityCandidate) -> PaletteColor {
        PaletteColor(
            id: fixture.index!,
            hex: fixture.hexColor,
            rgb: RGBColor(hex: fixture.hexColor)!,
            responses: channels(from: fixture.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func channels(from values: [String: Double]) -> [LightingCondition: Double] {
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
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityCandidate]
    let target: ParityCandidate
    let weights: [String: Double]
    let expected: ParityExpectation
}

private struct ParityCandidate: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpectation: Decodable {
    let error: Double?
    let selectedIndex: Int?
    let tiedIndices: [Int]
    let scores: [ParityCandidateScore]
}

private struct ParityCandidateScore: Decodable, Equatable {
    enum Score: Equatable {
        case value(Double)
        case excluded
    }

    let index: Int
    let score: Score

    private enum CodingKeys: String, CodingKey { case index, score }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        if let value = try? container.decode(Double.self, forKey: .score) {
            score = .value(value)
        } else if try container.decode(String.self, forKey: .score) == "excluded" {
            score = .excluded
        } else {
            throw DecodingError.dataCorruptedError(forKey: .score, in: container, debugDescription: "Expected a score or excluded")
        }
    }
}
