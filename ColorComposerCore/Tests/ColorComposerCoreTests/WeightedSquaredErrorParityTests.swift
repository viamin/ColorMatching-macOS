import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testMatchesVersionOneParityCorpusExactly() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus["algorithm_version"] as? Int, 1)
        XCTAssertEqual(corpus["selection"] as? String, "earliest-index-wins")
        XCTAssertEqual(
            corpus["missing_policy"] as? String,
            "excluded-when-any-positive-weight-channel-missing"
        )

        let scenarios = try requiredArray(corpus["scenarios"], named: "scenarios")
        XCTAssertFalse(scenarios.isEmpty)

        for scenario in scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: [String: Any]) throws {
        let id = try requiredString(scenario["id"], named: "scenario id")
        let weights = try channelWeights(from: scenario["weights"])
        let target = try targetVector(from: scenario["target"])
        let paletteEntries = try requiredArray(scenario["palette"], named: "palette")
        let palette = try paletteEntries.enumerated().map { index, entry in
            try paletteColor(from: entry, fallbackID: index)
        }
        let expected = try requiredObject(scenario["expected"], named: "expected")
        let expectedScores = try requiredArray(expected["scores"], named: "expected scores")

        XCTAssertEqual(expectedScores.count, palette.count, "\(id): every candidate has an expected score")

        let scorer = WeightedSquaredErrorScorer()
        var selectedIndex: Int?
        var selectedScore: Double?
        var tiedIndices: [Int] = []

        for (index, candidate) in palette.enumerated() {
            let expectedScore = try requiredObject(expectedScores[index], named: "expected score")
            XCTAssertEqual(expectedScore["index"] as? Int, index, "\(id): score order")

            let actual = scorer.score(candidate: candidate, target: target, weights: weights)
            try assert(actual, matches: expectedScore["score"], scenarioID: id, index: index)

            guard case .score(let score) = actual else { continue }
            guard let currentScore = selectedScore else {
                selectedIndex = index
                selectedScore = score
                tiedIndices = [index]
                continue
            }
            if score < currentScore {
                selectedIndex = index
                selectedScore = score
                tiedIndices = [index]
            } else if score == currentScore {
                tiedIndices.append(index)
            }
        }

        let expectedIndex = expected["selected_index"] as? Int
        XCTAssertEqual(selectedIndex, expectedIndex, "\(id): selected palette index")
        XCTAssertEqual(
            selectedIndex.map { palette[$0].hex },
            expected["selected_hex_color"] as? String,
            "\(id): selected palette color"
        )
        XCTAssertEqual(tiedIndices, expected["tied_indices"] as? [Int] ?? [], "\(id): tie indices")
        let tieBroke = selectedIndex.map { _ in tiedIndices.count > 1 }
        XCTAssertEqual(expected["tie_broke"] as? Bool, tieBroke, "\(id): tie outcome")

        if let expectedError = expected["error"] as? Double {
            guard let selectedScore else {
                return XCTFail("\(id): expected a selected error")
            }
            XCTAssertEqual(selectedScore, expectedError, accuracy: 1e-12, "\(id): selected error")
        } else {
            XCTAssertNil(selectedScore, "\(id): every candidate should be excluded")
        }
    }

    private func assert(
        _ actual: ScorerResult,
        matches expected: Any?,
        scenarioID: String,
        index: Int
    ) throws {
        if let expectedScore = expected as? Double {
            guard case .score(let actualScore) = actual else {
                return XCTFail("\(scenarioID): candidate \(index) was unexpectedly excluded")
            }
            XCTAssertEqual(actualScore, expectedScore, accuracy: 1e-12, "\(scenarioID): candidate \(index) score")
        } else {
            XCTAssertEqual(expected as? String, "excluded", "\(scenarioID): unsupported corpus score")
            XCTAssertEqual(actual, .excluded, "\(scenarioID): candidate \(index) exclusion")
        }
    }

    private func loadCorpus() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let data = try Data(contentsOf: url)
        return try requiredObject(JSONSerialization.jsonObject(with: data), named: "parity corpus")
    }

    private func channelWeights(from value: Any?) throws -> ChannelWeights {
        let values = try requiredObject(value, named: "weights")
        return ChannelWeights(
            white: values["white"] as? Double ?? 0,
            red: values["red"] as? Double ?? 0,
            green: values["green"] as? Double ?? 0,
            blue: values["blue"] as? Double ?? 0,
            lps: values["lps"] as? Double ?? 0
        )
    }

    private func targetVector(from value: Any?) throws -> TargetResponseVector {
        TargetResponseVector(try channels(from: value))
    }

    private func paletteColor(from value: Any, fallbackID: Int) throws -> PaletteColor {
        let entry = try requiredObject(value, named: "palette entry")
        let hex = try requiredString(entry["hex_color"], named: "palette hex")
        guard let rgb = RGBColor(hex: hex) else { throw CorpusError.invalidHex(hex) }
        let responses = try channels(from: entry).mapValues(IlluminationResponse.init(brightness:))
        return PaletteColor(id: entry["index"] as? Int ?? fallbackID, hex: hex, rgb: rgb, responses: responses)
    }

    private func channels(from value: Any?) throws -> [LightingCondition: Double] {
        let entry = try requiredObject(value, named: "vector")
        let encoded = try requiredObject(entry["channels"], named: "channels")
        return encoded.reduce(into: [:]) { channels, pair in
            guard let condition = LightingCondition(rawValue: pair.key), let brightness = pair.value as? Double else {
                return
            }
            channels[condition] = brightness
        }
    }

    private func requiredObject(_ value: Any?, named name: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw CorpusError.invalidShape(name) }
        return object
    }

    private func requiredArray(_ value: Any?, named name: String) throws -> [Any] {
        guard let array = value as? [Any] else { throw CorpusError.invalidShape(name) }
        return array
    }

    private func requiredString(_ value: Any?, named name: String) throws -> String {
        guard let string = value as? String else { throw CorpusError.invalidShape(name) }
        return string
    }
}

private enum CorpusError: Error {
    case invalidHex(String)
    case invalidShape(String)
}
