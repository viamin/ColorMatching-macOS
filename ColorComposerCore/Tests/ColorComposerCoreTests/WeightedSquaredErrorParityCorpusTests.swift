import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    private let corpusURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")

    func testReplaysCommittedWeightedSquaredErrorParityCorpus() throws {
        let corpus = try dictionary(from: corpusURL)

        XCTAssertEqual(corpus["algorithm_version"] as? Int, 1)
        XCTAssertEqual(corpus["selection"] as? String, "earliest-index-wins")
        XCTAssertEqual(
            corpus["missing_policy"] as? String,
            "excluded-when-any-positive-weight-channel-missing"
        )

        let scenarios = try array(named: "scenarios", in: corpus)
        XCTAssertFalse(scenarios.isEmpty)
        let containsTie = try scenarios.contains { rawScenario in
            let scenario = try dictionary(rawScenario)
            let expected = try dictionary(named: "expected", in: scenario)
            return try bool(named: "tie_broke", in: expected)
        }
        XCTAssertTrue(containsTie)

        for rawScenario in scenarios {
            let scenario = try dictionary(rawScenario)
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: [String: Any]) throws {
        let id = try string(named: "id", in: scenario)
        let weights = try channelWeights(from: dictionary(named: "weights", in: scenario))
        let target = try target(from: dictionary(named: "target", in: scenario))
        let palette = try palette(from: array(named: "palette", in: scenario))
        let expected = try dictionary(named: "expected", in: scenario)
        let expectedScores = try array(named: "scores", in: expected)

        XCTAssertEqual(palette.count, expectedScores.count, "\(id): corpus score count")

        let scorer = WeightedSquaredErrorScorer()
        let scores = try zip(palette, expectedScores).map { candidate, rawExpected -> ScorerResult in
            let expectedScore = try dictionary(rawExpected)
            let expectedValue = expectedScore["score"]
            let actual = scorer.score(candidate: candidate, target: target, weights: weights)
            assert(actual, matches: expectedValue, scenarioID: id, candidateID: candidate.id)
            return actual
        }

        try assertSelection(
            scenarioID: id,
            palette: palette,
            target: target,
            weights: weights,
            scores: scores,
            expected: expected
        )
    }

    private func assertSelection(
        scenarioID: String,
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights,
        scores: [ScorerResult],
        expected: [String: Any]
    ) throws {
        let selectedIndex = expected["selected_index"] as? Int
        let expectedTies = try array(named: "tied_indices", in: expected).compactMap { $0 as? Int }
        let bestScore = scores.compactMap(scoreValue).min()
        let actualTies: [Int]
        if let bestScore {
            actualTies = scores.enumerated().compactMap { index, result in
                scoreValue(result) == bestScore ? index : nil
            }
        } else {
            actualTies = []
        }

        XCTAssertEqual(actualTies, expectedTies, "\(scenarioID): tied indices")
        XCTAssertEqual((actualTies.count > 1), try bool(named: "tie_broke", in: expected), "\(scenarioID): tie evidence")

        guard let selectedIndex else {
            XCTAssertNil(bestScore, "\(scenarioID): expected no selection")
            return
        }

        XCTAssertEqual(actualTies.first, selectedIndex, "\(scenarioID): earliest tied candidate wins")
        XCTAssertEqual(palette[selectedIndex].hex, try string(named: "selected_hex_color", in: expected))
        XCTAssertEqual(bestScore, try number(named: "error", in: expected), accuracy: 1e-12, "\(scenarioID): selected error")

        guard weights.activeConditions.allSatisfy({ target.value(for: $0) != nil }) else { return }

        let sourceGrids = Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [target.value(for: condition)!]))
        })
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: sourceGrids, weights: weights)
        XCTAssertEqual(result.colorIndex(x: 0, y: 0), selectedIndex, "\(scenarioID): solver selection")
        XCTAssertEqual(result.error(x: 0, y: 0), bestScore!, accuracy: 1e-12, "\(scenarioID): solver error")
    }

    private func assert(_ actual: ScorerResult, matches expected: Any?, scenarioID: String, candidateID: Int) {
        if let expected = expected as? String {
            XCTAssertEqual(actual, .excluded, "\(scenarioID): candidate \(candidateID) should be \(expected)")
            return
        }

        guard case .score(let actualScore) = actual, let expected = expected as? NSNumber else {
            return XCTFail("\(scenarioID): candidate \(candidateID) score shape mismatch")
        }
        XCTAssertEqual(actualScore, expected.doubleValue, accuracy: 1e-12, "\(scenarioID): candidate \(candidateID) score")
    }

    private func scoreValue(_ result: ScorerResult) -> Double? {
        guard case .score(let score) = result else { return nil }
        return score
    }

    private func palette(from rawPalette: [Any]) throws -> [PaletteColor] {
        try rawPalette.map { rawCandidate in
            let candidate = try dictionary(rawCandidate)
            let id = try int(named: "index", in: candidate)
            let hex = try string(named: "hex_color", in: candidate)
            let channels = try dictionary(named: "channels", in: candidate)
            let responses = try responses(from: channels)
            return PaletteColor(id: id, hex: hex, rgb: try XCTUnwrap(RGBColor(hex: hex)), responses: responses)
        }
    }

    private func target(from rawTarget: [String: Any]) throws -> TargetResponseVector {
        let channels = try dictionary(named: "channels", in: rawTarget)
        return TargetResponseVector(try brightnesses(from: channels))
    }

    private func channelWeights(from rawWeights: [String: Any]) throws -> ChannelWeights {
        ChannelWeights(
            white: try number(named: "white", in: rawWeights, default: 0),
            red: try number(named: "red", in: rawWeights, default: 0),
            green: try number(named: "green", in: rawWeights, default: 0),
            blue: try number(named: "blue", in: rawWeights, default: 0),
            lps: try number(named: "lps", in: rawWeights, default: 0)
        )
    }

    private func responses(from channels: [String: Any]) throws -> [LightingCondition: IlluminationResponse] {
        try brightnesses(from: channels).mapValues(IlluminationResponse.init(brightness:))
    }

    private func brightnesses(from channels: [String: Any]) throws -> [LightingCondition: Double] {
        let entries = LightingCondition.all.compactMap { condition in
            guard let value = channels[condition.rawValue] as? NSNumber else { return nil }
            return (condition, value.doubleValue)
        }
        return Dictionary(uniqueKeysWithValues: entries)
    }

    private func dictionary(from dataURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: dataURL)
        return try dictionary(JSONSerialization.jsonObject(with: data))
    }

    private func dictionary(_ value: Any) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any])
    }

    private func dictionary(named key: String, in dictionary: [String: Any]) throws -> [String: Any] {
        try self.dictionary(XCTUnwrap(dictionary[key]))
    }

    private func array(named key: String, in dictionary: [String: Any]) throws -> [Any] {
        try XCTUnwrap(dictionary[key] as? [Any])
    }

    private func string(named key: String, in dictionary: [String: Any]) throws -> String {
        try XCTUnwrap(dictionary[key] as? String)
    }

    private func int(named key: String, in dictionary: [String: Any]) throws -> Int {
        try XCTUnwrap(dictionary[key] as? Int)
    }

    private func bool(named key: String, in dictionary: [String: Any]) throws -> Bool {
        try XCTUnwrap(dictionary[key] as? Bool)
    }

    private func number(named key: String, in dictionary: [String: Any], default defaultValue: Double? = nil) throws -> Double {
        if let value = dictionary[key] as? NSNumber { return value.doubleValue }
        return try XCTUnwrap(defaultValue)
    }
}
