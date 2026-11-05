import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    private let corpusURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/v1/corpus.json")

    func testCorpusMetadataAndCoverage() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertFalse(corpus.scenarios.isEmpty)
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })
    }

    func testWeightedSquaredErrorReplaysCommittedParityCorpus() throws {
        for scenario in try loadCorpus().scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let palette = try scenario.palette.map(makePaletteColor)
        let target = TargetResponseVector(knownChannels(in: scenario.target.channels))
        let weights = makeWeights(from: scenario.weights)
        let scorer = WeightedSquaredErrorScorer()

        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
        assertScores(actualScores, equal: scenario.expected.scores, scenarioID: scenario.id)
        assertDirectSelection(actualScores, equals: scenario.expected, scenarioID: scenario.id)

        if scenario.targetHasEveryActiveChannel {
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: sourceGrids(for: scenario),
                weights: weights
            )
            XCTAssertEqual(result.colorIndices, [scenario.expected.selectedIndex], scenario.id)
            if let expectedError = scenario.expected.error {
                XCTAssertEqual(result.errors, [expectedError], scenario.id)
            } else {
                XCTAssertTrue(result.errors[0].isInfinite, scenario.id)
            }
        }
    }

    private func assertScores(
        _ actual: [ScorerResult],
        equal expected: [ExpectedScore],
        scenarioID: String
    ) {
        XCTAssertEqual(actual.count, expected.count, scenarioID)
        for (result, expectation) in zip(actual, expected.sorted { $0.index < $1.index }) {
            switch (result, expectation.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actualScore), .value(let expectedScore)):
                XCTAssertEqual(actualScore, expectedScore, scenarioID)
            default:
                XCTFail("\(scenarioID): score at index \(expectation.index) differs from corpus")
            }
        }
    }

    private func assertDirectSelection(
        _ scores: [ScorerResult],
        equals expected: ExpectedSelection,
        scenarioID: String
    ) {
        let eligible = scores.enumerated().compactMap { index, score -> (Int, Double)? in
            guard case .score(let value) = score else { return nil }
            return (index, value)
        }
        let selected = eligible.min { $0.1 < $1.1 }
        let tied = selected.map { selected in
            eligible.filter { $0.1 == selected.1 }.map(\.0)
        } ?? []

        XCTAssertEqual(selected?.0, expected.selectedIndex, scenarioID)
        XCTAssertEqual(selected?.1, expected.error, scenarioID)
        XCTAssertEqual(tied, expected.tiedIndices, scenarioID)
        XCTAssertEqual(expected.tieBroke, tied.count > 1 ? true : (tied.isEmpty ? nil : false), scenarioID)
    }

    private func sourceGrids(for scenario: ParityScenario) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: scenario.weights.compactMap { condition, weight in
            guard weight > 0,
                  let lightingCondition = LightingCondition(rawValue: condition),
                  let brightness = scenario.target.channels[condition]
            else { return nil }
            return (lightingCondition, BrightnessGrid(width: 1, height: 1, values: [brightness]))
        })
    }

    private func makePaletteColor(_ entry: ParityVector) throws -> PaletteColor {
        let responses = knownChannels(in: entry.channels)
            .mapValues(IlluminationResponse.init(brightness:))
        return PaletteColor(
            id: entry.index ?? 0,
            hex: entry.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: entry.hexColor)),
            responses: responses
        )
    }

    private func makeWeights(from encoded: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: encoded["white"] ?? 0,
            red: encoded["red"] ?? 0,
            green: encoded["green"] ?? 0,
            blue: encoded["blue"] ?? 0,
            lps: encoded["lps"] ?? 0
        )
    }

    private func knownChannels(in encoded: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: encoded.compactMap { name, value in
            LightingCondition(rawValue: name).map { ($0, value) }
        })
    }

    private func loadCorpus() throws -> ParityCorpus {
        let data = try Data(contentsOf: corpusURL)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: data)
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: ParityVector
    let palette: [ParityVector]
    let expected: ExpectedSelection

    var targetHasEveryActiveChannel: Bool {
        weights.allSatisfy { name, weight in
            weight <= 0 || LightingCondition(rawValue: name) == nil || target.channels[name] != nil
        }
    }
}

private struct ParityVector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ExpectedSelection: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedIndex: Int?
    let selectedHexColor: String?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ExpectedScore: Decodable {
    enum Score: Equatable {
        case excluded
        case value(Double)
    }

    let index: Int
    let score: Score

    private enum CodingKeys: String, CodingKey {
        case index, score
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        if let value = try? container.decode(Double.self, forKey: .score) {
            score = .value(value)
        } else {
            guard try container.decode(String.self, forKey: .score) == "excluded" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .score,
                    in: container,
                    debugDescription: "score must be a number or 'excluded'"
                )
            }
            score = .excluded
        }
    }
}
