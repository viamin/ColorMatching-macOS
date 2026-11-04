import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testV1CorpusMatchesScoresAndSelections() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            let palette = try scenario.palette.enumerated().map { offset, color in
                try paletteColor(color, fallbackID: offset)
            }
            let target = try targetVector(scenario.target.channels)
            let weights = try channelWeights(scenario.weights)
            let scorer = WeightedSquaredErrorScorer()

            for expectedScore in scenario.expected.scores {
                let actual = scorer.score(
                    candidate: palette[expectedScore.index], target: target, weights: weights
                )
                assertScore(actual, matches: expectedScore.score, scenarioID: scenario.id)
            }

            // A source grid represents every active channel. The corpus's
            // missing-target case is therefore asserted above at scorer level.
            guard Set(weights.activeConditions).isSubset(of: Set(target.values.keys)) else {
                XCTAssertNil(scenario.expected.selectedIndex, scenario.id)
                continue
            }

            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: sourceGrids(from: target, activeConditions: weights.activeConditions),
                weights: weights
            )

            if let selectedIndex = scenario.expected.selectedIndex {
                XCTAssertEqual(result.colorIndex(x: 0, y: 0), selectedIndex, scenario.id)
                XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor, scenario.id)
                XCTAssertEqual(result.error(x: 0, y: 0), scenario.expected.error!, accuracy: 1e-12, scenario.id)
            } else {
                XCTAssertTrue(
                    scenario.expected.scores.allSatisfy { $0.score == .excluded },
                    "\(scenario.id) has no selection only when every candidate is excluded"
                )
                XCTAssertNil(result.colorIndex(x: 0, y: 0), scenario.id)
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fileURL))
    }

    private func paletteColor(_ color: CorpusColor, fallbackID: Int) throws -> PaletteColor {
        PaletteColor(
            id: color.index ?? fallbackID,
            hex: color.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: color.hexColor)),
            responses: try responses(from: color.channels)
        )
    }

    private func targetVector(_ channels: [String: Double]) throws -> TargetResponseVector {
        TargetResponseVector(try lightingValues(from: channels))
    }

    private func responses(from channels: [String: Double]) throws -> [LightingCondition: IlluminationResponse] {
        try lightingValues(from: channels).mapValues(IlluminationResponse.init(brightness:))
    }

    private func lightingValues(from channels: [String: Double]) throws -> [LightingCondition: Double] {
        try Dictionary(uniqueKeysWithValues: channels.compactMap { name, value in
            guard let condition = LightingCondition(rawValue: name) else { return nil }
            return (condition, value)
        })
    }

    private func channelWeights(_ weights: [String: Double]) throws -> ChannelWeights {
        ChannelWeights(
            white: weights["white", default: 0], red: weights["red", default: 0],
            green: weights["green", default: 0], blue: weights["blue", default: 0],
            lps: weights["lps", default: 0]
        )
    }

    private func sourceGrids(
        from target: TargetResponseVector,
        activeConditions: [LightingCondition]
    ) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: activeConditions.map {
            ($0, BrightnessGrid(width: 1, height: 1, fill: target.value(for: $0)!))
        })
    }

    private func assertScore(
        _ actual: ScorerResult,
        matches expected: CorpusScore,
        scenarioID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            return
        case (.score(let actual), .value(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, scenarioID, file: file, line: line)
        default:
            XCTFail("\(scenarioID): expected \(expected), received \(actual)", file: file, line: line)
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [CorpusColor]
    let target: CorpusColor
    let weights: [String: Double]
    let expected: ExpectedResult
}

private struct CorpusColor: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ExpectedResult: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
}

private struct ExpectedScore: Decodable {
    let index: Int
    let score: CorpusScore
}

private enum CorpusScore: Decodable, Equatable, CustomStringConvertible {
    case excluded
    case value(Double)

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .value(let value): return String(value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected score or excluded")
        }
    }
}
