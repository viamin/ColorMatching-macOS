import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testReplaysCommittedColorMatchingParityCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: Scenario, file: StaticString = #filePath, line: UInt = #line) throws {
        let palette = try scenario.palette.enumerated().map { index, vector in
            try PaletteColor(
                id: index,
                hex: vector.hex,
                rgb: XCTUnwrap(RGBColor(hex: vector.hex)),
                responses: responses(from: vector.channels)
            )
        }
        let target = TargetResponseVector(values(from: scenario.target))
        let weights = ChannelWeights(channels: scenario.weights)
        let scorer = WeightedSquaredErrorScorer()
        let scores = palette.map { scorer.score(candidate: $0, target: target, weights: weights).value }

        XCTAssertEqual(scores.count, scenario.expected.scores.count, scenario.id, file: file, line: line)
        for (actual, expected) in zip(scores, scenario.expected.scores) {
            switch (actual, expected) {
            case let (.some(actual), .some(expected)):
                XCTAssertEqual(actual, expected, accuracy: 1e-12, "\(scenario.id): candidate score", file: file, line: line)
            case (.none, .none):
                break
            default:
                XCTFail("\(scenario.id): candidate exclusion did not match corpus", file: file, line: line)
            }
        }

        let eligible = scores.enumerated().compactMap { index, score in score.map { (index, $0) } }
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: grids(from: scenario.target, weights: weights),
            weights: weights
        )

        guard let expectedIndex = scenario.expected.selectedIndex else {
            XCTAssertTrue(eligible.isEmpty, scenario.id, file: file, line: line)
            XCTAssertNil(result.colorIndex(x: 0, y: 0), scenario.id, file: file, line: line)
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id, file: file, line: line)
            return
        }

        let expectedError = try XCTUnwrap(scenario.expected.error)
        let expectedHex = try XCTUnwrap(scenario.expected.selectedHex)
        XCTAssertEqual(result.colorIndex(x: 0, y: 0), expectedIndex, scenario.id, file: file, line: line)
        XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id, file: file, line: line)
        XCTAssertEqual(palette[expectedIndex].hex, expectedHex, scenario.id, file: file, line: line)
        XCTAssertEqual(
            eligible.filter { $0.1 == expectedError }.map(\.0),
            scenario.expected.tiedIndices,
            scenario.id,
            file: file,
            line: line
        )
    }

    private func loadCorpus() throws -> Corpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: fixture))
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, value in
            LightingCondition(rawValue: name).map { ($0, IlluminationResponse(brightness: value)) }
        })
    }

    private func values(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, value in
            LightingCondition(rawValue: name).map { ($0, value) }
        })
    }

    private func grids(from target: [String: Double], weights: ChannelWeights) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [target[condition.rawValue] ?? 0]))
        })
    }
}

private extension ScorerResult {
    var value: Double? {
        if case .score(let value) = self { return value }
        return nil
    }
}

private extension ChannelWeights {
    init(channels: [String: Double]) {
        self.init(
            white: channels["white"] ?? 0,
            red: channels["red"] ?? 0,
            green: channels["green"] ?? 0,
            blue: channels["blue"] ?? 0,
            lps: channels["lps"] ?? 0
        )
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
    let scenarios: [Scenario]

    private enum CodingKeys: String, CodingKey {
        case scorer, selection, scenarios
        case algorithmVersion = "algorithm_version"
        case missingPolicy = "missing_policy"
        case lightSources = "light_sources"
    }
}

private struct Scenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: [String: Double]
    let palette: [Vector]
    let expected: Expected
}

private struct Vector: Decodable {
    let hex: String
    let channels: [String: Double]
}

private struct Expected: Decodable {
    let scores: [Double?]
    let selectedIndex: Int?
    let selectedHex: String?
    let error: Double?
    let tiedIndices: [Int]

    private enum CodingKeys: String, CodingKey {
        case scores, error
        case selectedIndex = "selected_index"
        case selectedHex = "selected_hex"
        case tiedIndices = "tied_indices"
    }
}
