import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testPublishedV1CorpusMatchesScorerAndSolverSelections() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus["algorithm_version"] as? Int, 1)
        XCTAssertEqual(corpus["scorer"] as? String, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus["selection"] as? String, "earliest-index-wins")
        XCTAssertEqual(corpus["missing_policy"] as? String, "excluded-when-any-positive-weight-channel-missing")

        let scenarios = try XCTUnwrap(corpus["scenarios"] as? [[String: Any]])
        XCTAssertFalse(scenarios.isEmpty)

        for scenario in scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: [String: Any]) throws {
        let id = try XCTUnwrap(scenario["id"] as? String)
        let paletteEntries = try XCTUnwrap(scenario["palette"] as? [[String: Any]])
        let targetEntry = try XCTUnwrap(scenario["target"] as? [String: Any])
        let expected = try XCTUnwrap(scenario["expected"] as? [String: Any])
        let weights = weights(from: try XCTUnwrap(scenario["weights"] as? [String: Any]))
        let target = TargetResponseVector(channels(from: try XCTUnwrap(targetEntry["channels"] as? [String: Any])))
        let palette = try paletteEntries.map(makeColor)
        let expectedScores = try XCTUnwrap(expected["scores"] as? [[String: Any]])
        let scorer = WeightedSquaredErrorScorer()

        for expectedScore in expectedScores {
            let index = try XCTUnwrap(expectedScore["index"] as? Int)
            let actual = scorer.score(candidate: palette[index], target: target, weights: weights)
            if let score = expectedScore["score"] as? Double {
                guard case .score(let actualScore) = actual else {
                    return XCTFail("\(id): candidate \(index) should be scored")
                }
                XCTAssertEqual(actualScore, score, accuracy: 0, "\(id): candidate \(index)")
            } else {
                XCTAssertEqual(actual, .excluded, "\(id): candidate \(index)")
            }
        }

        let selectedIndex = expected["selected_index"] as? Int
        let ranked = palette.enumerated().compactMap { index, color -> (Int, Double)? in
            guard case .score(let score) = scorer.score(candidate: color, target: target, weights: weights) else {
                return nil
            }
            return (index, score)
        }
        let scorerSelection = ranked.reduce(nil as (Int, Double)?) { best, candidate in
            guard let best else { return candidate }
            return candidate.1 < best.1 ? candidate : best
        }?.0
        XCTAssertEqual(scorerSelection, selectedIndex, "\(id): scorer selection")

        if let selectedIndex, let expectedError = expected["error"] as? Double {
            let selectedScore = try XCTUnwrap(ranked.first(where: { $0.0 == selectedIndex })?.1)
            XCTAssertEqual(selectedScore, expectedError, accuracy: 0, "\(id): selected error")
            let sourceGrids = Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
                (condition, BrightnessGrid(width: 1, height: 1, values: [target.value(for: condition)!]))
            })
            let result = try CompositionSolver().solve(palette: palette, sourceGrids: sourceGrids, weights: weights)
            XCTAssertEqual(result.colorIndex(x: 0, y: 0), selectedIndex, "\(id): solver selection")
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 0, "\(id): solver error")
        }
    }

    private func loadCorpus() throws -> [String: Any] {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/color-matching-parity-v1.json")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
    }

    private func makeColor(_ entry: [String: Any]) throws -> PaletteColor {
        let index = try XCTUnwrap(entry["index"] as? Int)
        let hex = try XCTUnwrap(entry["hex_color"] as? String)
        let rgb = try XCTUnwrap(RGBColor(hex: hex))
        let responses = channels(from: try XCTUnwrap(entry["channels"] as? [String: Any]))
            .mapValues { IlluminationResponse(brightness: $0) }
        return PaletteColor(id: index, hex: hex, rgb: rgb, responses: responses)
    }

    private func channels(from values: [String: Any]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { name, value in
            guard let condition = LightingCondition(rawValue: name), let value = value as? Double else { return nil }
            return (condition, value)
        })
    }

    private func weights(from values: [String: Any]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] as? Double ?? 0,
            red: values["red"] as? Double ?? 0,
            green: values["green"] as? Double ?? 0,
            blue: values["blue"] as? Double ?? 0,
            lps: values["lps"] as? Double ?? 0
        )
    }
}
