import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testReplaysEveryCommittedWeightedSquaredErrorScenario() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.allCases.map(\.rawValue))
        XCTAssertFalse(corpus.scenarios.isEmpty)

        for scenario in corpus.scenarios {
            try assertScorerParity(for: scenario)
            try assertSolverParityWhenTargetIsComplete(for: scenario)
        }
    }

    private func assertScorerParity(for scenario: ParityScenario) throws {
        let palette = try scenario.palette.map(makeColor)
        let target = TargetResponseVector(try channels(from: scenario.target))
        let weights = weights(from: scenario.weights)
        let scorer = WeightedSquaredErrorScorer()

        let scores = try palette.enumerated().map { index, color -> Double? in
            let expected = try XCTUnwrap(
                scenario.expected.scores.first(where: { $0.index == index }),
                "Missing expected score for palette index \(index) in \(scenario.id)"
            )

            switch (scorer.score(candidate: color, target: target, weights: weights), expected.score) {
            case (.excluded, .excluded):
                return nil
            case (.score(let actual), .value(let expected)):
                XCTAssertEqual(actual, expected, accuracy: 1e-12, "\(scenario.id), palette index \(index)")
                return actual
            default:
                XCTFail("\(scenario.id), palette index \(index): scorer exclusion differs from corpus")
                return nil
            }
        }

        let minimum = scores.compactMap { $0 }.min()
        let tiedIndices = scores.enumerated().compactMap { index, score in
            score == minimum ? index : nil
        }

        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, "\(scenario.id): tied indices")
        let tieBroke: Bool? = tiedIndices.isEmpty ? nil : tiedIndices.count > 1
        XCTAssertEqual(scenario.expected.tieBroke, tieBroke, "\(scenario.id): tie evidence")
        XCTAssertEqual(tiedIndices.first, scenario.expected.selectedIndex, "\(scenario.id): earliest tie winner")
    }

    private func assertSolverParityWhenTargetIsComplete(for scenario: ParityScenario) throws {
        let active = weights(from: scenario.weights).activeConditions
        let targetChannels = try channels(from: scenario.target)
        guard active.allSatisfy({ targetChannels[$0] != nil }) else {
            XCTAssertNil(scenario.expected.selectedIndex, "\(scenario.id): incomplete target must be unselectable")
            return
        }

        let grids = Dictionary(uniqueKeysWithValues: active.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [targetChannels[condition]!]))
        })
        let result = try CompositionSolver().solve(
            palette: try scenario.palette.map(makeColor),
            sourceGrids: grids,
            weights: weights(from: scenario.weights)
        )

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, "\(scenario.id)")
        if let error = scenario.expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), error, accuracy: 1e-12, "\(scenario.id)")
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, "\(scenario.id)")
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makeColor(_ entry: ParityVector) throws -> PaletteColor {
        PaletteColor(
            id: try XCTUnwrap(entry.index),
            hex: entry.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: entry.hexColor)),
            responses: try channels(from: entry).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func channels(from entry: ParityVector) throws -> [LightingCondition: Double] {
        var result: [LightingCondition: Double] = [:]
        for (name, brightness) in entry.channels {
            guard let condition = LightingCondition(rawValue: name) else { continue }
            result[condition] = brightness
        }
        return result
    }

    private func weights(from encoded: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: encoded["white"] ?? 0,
            red: encoded["red"] ?? 0,
            green: encoded["green"] ?? 0,
            blue: encoded["blue"] ?? 0,
            lps: encoded["lps"] ?? 0
        )
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scenarios: [ParityScenario]
    let scorer: String
    let selection: String
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    enum Score: Equatable {
        case excluded
        case value(Double)
    }

    let index: Int
    let score: Score

    private enum CodingKeys: String, CodingKey {
        case index
        case score
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        if let value = try? container.decode(Double.self, forKey: .score) {
            score = .value(value)
        } else {
            XCTAssertEqual(try container.decode(String.self, forKey: .score), "excluded")
            score = .excluded
        }
    }
}
