import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the golden vectors published by `viamin/color_matching`.
///
/// The fixture is copied verbatim from
/// `priv/parity/v1/corpus.json` in the server repository. It locks down score,
/// exclusion, and earliest-index-wins selection semantics shared by the apps.
final class WeightedSquaredErrorParityTests: XCTestCase {
    private let scorer = WeightedSquaredErrorScorer()

    func testCorpusDeclaresTheSharedSolverContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus["algorithm_version"] as? Int, 1)
        XCTAssertEqual(corpus["scorer"] as? String, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus["selection"] as? String, "earliest-index-wins")
        XCTAssertEqual(corpus["missing_policy"] as? String, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus["light_sources"] as? [String], LightingCondition.all.map(\.rawValue))
    }

    func testReplaysEveryCorpusScenarioExactly() throws {
        let scenarios = try scenarios(in: loadCorpus())

        XCTAssertFalse(scenarios.isEmpty)
        XCTAssertTrue(scenarios.contains { ($0["expected"] as? [String: Any])?["tie_broke"] as? Bool == true })
        XCTAssertTrue(scenarios.contains { ($0["expected"] as? [String: Any])?["selected_index"] is NSNull })

        for scenario in scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: [String: Any]) throws {
        let id = try string("id", in: scenario)
        let target = try vector(from: dictionary("target", in: scenario), id: -1)
        let weights = try weights(from: dictionary("weights", in: scenario))
        let palette = try array("palette", in: scenario)
            .map { try vector(from: $0, id: try integer("index", in: $0)) }
            .sorted { $0.id < $1.id }
        let expected = try dictionary("expected", in: scenario)
        let expectedScores = try array("scores", in: expected)
            .sorted { try! integer("index", in: $0) < try! integer("index", in: $1) }

        let scores = palette.map { scorer.score(candidate: $0.color, target: target.response, weights: weights) }
        XCTAssertEqual(scores.count, expectedScores.count, id)
        for (actual, expectedScore) in zip(scores, expectedScores) {
            assertScore(actual, expected: expectedScore["score"], scenario: id)
        }

        let selection = firstLowestScore(in: scores)
        assertSelection(selection, scores: scores, palette: palette, expected: expected, scenario: id)
    }

    private func assertScore(_ actual: ScorerResult, expected: Any?, scenario: String) {
        if let expected = expected as? String {
            XCTAssertEqual(expected, "excluded", scenario)
            XCTAssertEqual(actual, .excluded, scenario)
            return
        }

        guard let expected = expected as? NSNumber else {
            return XCTFail("\(scenario): missing expected score")
        }
        guard case .score(let actualScore) = actual else {
            return XCTFail("\(scenario): expected score \(expected), got exclusion")
        }
        XCTAssertEqual(actualScore, expected.doubleValue, scenario)
    }

    private func assertSelection(
        _ selection: (index: Int, score: Double)?,
        scores: [ScorerResult],
        palette: [DecodedVector],
        expected: [String: Any],
        scenario: String
    ) {
        guard let expectedIndex = expected["selected_index"] as? NSNumber else {
            XCTAssertNil(selection, scenario)
            XCTAssertEqual(expected["tie_broke"] as? Bool, nil, scenario)
            XCTAssertEqual(integerArray(expected["tied_indices"]), [], scenario)
            return
        }

        guard let selection else { return XCTFail("\(scenario): expected a selection") }
        XCTAssertEqual(selection.index, expectedIndex.intValue, scenario)
        XCTAssertEqual(palette[selection.index].hex, expected["selected_hex_color"] as? String, scenario)
        XCTAssertEqual(selection.score, (expected["error"] as? NSNumber)?.doubleValue, scenario)

        let tiedIndices = scores.enumerated().compactMap { index, result -> Int? in
            guard case .score(let score) = result, score == selection.score else { return nil }
            return index
        }
        XCTAssertEqual(tiedIndices, integerArray(expected["tied_indices"]), scenario)
        XCTAssertEqual(expected["tie_broke"] as? Bool, tiedIndices.count > 1, scenario)
        XCTAssertEqual(tiedIndices.first, selection.index, scenario)
    }

    private func firstLowestScore(in scores: [ScorerResult]) -> (index: Int, score: Double)? {
        var best: (index: Int, score: Double)?
        for (index, result) in scores.enumerated() {
            guard case .score(let score) = result else { continue }
            if best == nil || score < best!.score { best = (index, score) }
        }
        return best
    }

    private func loadCorpus() throws -> [String: Any] {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity_v1.json")
        let data = try Data(contentsOf: fixtureURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func scenarios(in corpus: [String: Any]) throws -> [[String: Any]] {
        try array("scenarios", in: corpus)
    }

    private func vector(from encoded: [String: Any], id: Int) throws -> DecodedVector {
        let channels = try dictionary("channels", in: encoded)
        let responses = try channels.reduce(into: [LightingCondition: IlluminationResponse]()) { result, entry in
            guard let condition = LightingCondition(rawValue: entry.key), let value = entry.value as? NSNumber else {
                throw FixtureError.malformed
            }
            result[condition] = IlluminationResponse(brightness: value.doubleValue)
        }
        let hex = try string("hex_color", in: encoded)
        let rgb = try XCTUnwrap(RGBColor(hex: hex))
        let color = PaletteColor(id: id, hex: hex, rgb: rgb, responses: responses)
        return DecodedVector(color: color, response: TargetResponseVector(responses.mapValues(\.brightness)), hex: hex, id: id)
    }

    private func weights(from encoded: [String: Any]) throws -> ChannelWeights {
        func value(_ condition: LightingCondition) throws -> Double {
            guard let value = encoded[condition.rawValue] as? NSNumber else { throw FixtureError.malformed }
            return value.doubleValue
        }
        return try ChannelWeights(white: value(.white), red: value(.red), green: value(.green), blue: value(.blue), lps: value(.lps))
    }

    private func dictionary(_ key: String, in object: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(object[key] as? [String: Any])
    }

    private func array(_ key: String, in object: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(object[key] as? [[String: Any]])
    }

    private func string(_ key: String, in object: [String: Any]) throws -> String {
        try XCTUnwrap(object[key] as? String)
    }

    private func integer(_ key: String, in object: [String: Any]) throws -> Int {
        try XCTUnwrap((object[key] as? NSNumber)?.intValue)
    }

    private func integerArray(_ value: Any?) -> [Int] {
        (value as? [NSNumber])?.map(\.intValue) ?? []
    }
}

private struct DecodedVector {
    let color: PaletteColor
    let response: TargetResponseVector
    let hex: String
    let id: Int
}

private enum FixtureError: Error {
    case malformed
}
