import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testMatchesCommittedElixirParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus["algorithm_version"] as? Int, 1)
        XCTAssertEqual(corpus["selection"] as? String, "earliest-index-wins")

        for scenario in try scenarios(in: corpus) {
            try assertScoresMatch(scenario)
            try assertSelectionMatches(scenario)
        }
    }

    private func assertScoresMatch(_ scenario: [String: Any]) throws {
        let scenarioID = scenario["id"] as? String ?? "<unnamed>"
        let scorer = WeightedSquaredErrorScorer()
        let target = target(from: try dictionary(scenario, key: "target"))
        let weights = weights(from: try dictionary(scenario, key: "weights"))
        let expected = try dictionary(scenario, key: "expected")
        let expectedScores = try array(expected, key: "scores")
        let palette = try palette(from: scenario)

        XCTAssertEqual(palette.count, expectedScores.count, scenarioID)
        for (candidate, expectedScore) in zip(palette, expectedScores) {
            XCTAssertEqual(candidate.id, expectedScore["index"] as? Int, scenarioID)
            let expectedValue = try XCTUnwrap(expectedScore["score"])
            switch scorer.score(candidate: candidate, target: target, weights: weights) {
            case .excluded:
                XCTAssertEqual(expectedValue as? String, "excluded", scenarioID)
            case .score(let actual):
                let value = try XCTUnwrap(expectedValue as? Double, scenarioID)
                XCTAssertEqual(actual, value, accuracy: 1e-12, scenarioID)
            }
        }
    }

    private func assertSelectionMatches(_ scenario: [String: Any]) throws {
        let scenarioID = scenario["id"] as? String ?? "<unnamed>"
        let weights = weights(from: try dictionary(scenario, key: "weights"))
        let target = try dictionary(scenario, key: "target")
        let targetChannels = try dictionary(target, key: "channels")
        let expected = try dictionary(scenario, key: "expected")
        let expectedIndex = expected["selected_index"] as? Int

        // A target missing an active channel is verified by score assertions above.
        // It cannot be represented as a source grid for the composition solver.
        guard weights.activeConditions.allSatisfy({ targetChannels[$0.rawValue] != nil }) else {
            XCTAssertNil(expectedIndex, scenarioID)
            return
        }

        let result = try CompositionSolver().solve(
            palette: try palette(from: scenario),
            sourceGrids: try sourceGrids(from: targetChannels, weights: weights),
            weights: weights
        )
        XCTAssertEqual(result.colorIndex(x: 0, y: 0), expectedIndex, scenarioID)
        XCTAssertEqual(
            result.colorIndex(x: 0, y: 0).map { result.palette[$0].hex },
            expected["selected_hex_color"] as? String,
            scenarioID
        )

        if let expectedError = expected["error"] as? Double {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenarioID)
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenarioID)
        }
    }

    private func loadCorpus() throws -> [String: Any] {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let data = try Data(contentsOf: fixture)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func scenarios(in corpus: [String: Any]) throws -> [[String: Any]] {
        try array(corpus, key: "scenarios")
    }

    private func palette(from scenario: [String: Any]) throws -> [PaletteColor] {
        try array(scenario, key: "palette").map { candidate in
            let channels = try dictionary(candidate, key: "channels")
            let hex = try XCTUnwrap(candidate["hex_color"] as? String)
            let id = try XCTUnwrap(candidate["index"] as? Int)
            let rgb = try XCTUnwrap(RGBColor(hex: hex))
            let responses = Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
                guard let condition = LightingCondition(rawValue: key), let brightness = value as? Double else {
                    return nil
                }
                return (condition, IlluminationResponse(brightness: brightness))
            })
            return PaletteColor(id: id, hex: hex, rgb: rgb, responses: responses)
        }
    }

    private func target(from dictionary: [String: Any]) -> TargetResponseVector {
        let channels = (dictionary["channels"] as? [String: Any]) ?? [:]
        return TargetResponseVector(Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            guard let condition = LightingCondition(rawValue: key), let brightness = value as? Double else {
                return nil
            }
            return (condition, brightness)
        }))
    }

    private func weights(from dictionary: [String: Any]) -> ChannelWeights {
        ChannelWeights(
            white: dictionary["white"] as? Double ?? 0,
            red: dictionary["red"] as? Double ?? 0,
            green: dictionary["green"] as? Double ?? 0,
            blue: dictionary["blue"] as? Double ?? 0,
            lps: dictionary["lps"] as? Double ?? 0
        )
    }

    private func sourceGrids(from channels: [String: Any], weights: ChannelWeights) throws -> [LightingCondition: BrightnessGrid] {
        try Dictionary(uniqueKeysWithValues: weights.activeConditions.map {
            let brightness = try XCTUnwrap(channels[$0.rawValue] as? Double)
            return ($0, BrightnessGrid(width: 1, height: 1, values: [brightness]))
        })
    }

    private func dictionary(_ dictionary: [String: Any], key: String) throws -> [String: Any] {
        try XCTUnwrap(dictionary[key] as? [String: Any], key)
    }

    private func array(_ dictionary: [String: Any], key: String) throws -> [[String: Any]] {
        try XCTUnwrap(dictionary[key] as? [[String: Any]], key)
    }
}
