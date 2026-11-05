import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: ParityScenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let weights = ChannelWeights(channels: scenario.weights)
        let target = TargetResponseVector(scenario.target.channels.lightingValues)
        let palette = try scenario.palette.map { try $0.paletteColor }

        for expectedScore in scenario.expected.scores {
            let result = scorer.score(
                candidate: palette[expectedScore.index], target: target, weights: weights
            )
            assert(result, matches: expectedScore.score, scenario: scenario.id, index: expectedScore.index)
        }

        guard let expectedError = scenario.expected.error else {
            XCTAssertNil(scenario.expected.selectedIndex, scenario.id)
            XCTAssertTrue(scenario.expected.tiedIndices.isEmpty, scenario.id)
            return
        }

        let matchingIndices = scenario.expected.scores.compactMap { score in
            score.score.doubleValue == expectedError ? score.index : nil
        }
        XCTAssertEqual(matchingIndices, scenario.expected.tiedIndices, scenario.id)

        let selectedIndex = try XCTUnwrap(scenario.expected.selectedIndex, scenario.id)

        let grids = try grids(for: scenario.target.channels, weights: weights)
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)
        XCTAssertEqual(result.colorIndex(x: 0, y: 0), selectedIndex, scenario.id)
        XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
        XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor, scenario.id)
    }

    private func assert(
        _ result: ScorerResult,
        matches expected: ParityScore,
        scenario: String,
        index: Int
    ) {
        switch (result, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "\(scenario), candidate \(index)")
        default:
            XCTFail("\(scenario), candidate \(index): expected \(expected), got \(result)")
        }
    }

    private func grids(
        for target: [String: Double], weights: ChannelWeights
    ) throws -> [LightingCondition: BrightnessGrid] {
        try Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            let value = try XCTUnwrap(target[condition.rawValue], "Missing target \(condition.rawValue)")
            return (condition, BrightnessGrid(width: 1, height: 1, values: [value]))
        })
    }

    private func loadCorpus() throws -> ParityCorpus {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: file))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityColor]
    let target: ParityColor
    let weights: [String: Double]
    let expected: ParityExpectation
}

private struct ParityColor: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?

    var paletteColor: PaletteColor {
        get throws {
            PaletteColor(
                id: index ?? -1,
                hex: hexColor,
                rgb: try XCTUnwrap(RGBColor(hex: hexColor)),
                responses: channels.lightingValues.mapValues(IlluminationResponse.init(brightness:))
            )
        }
    }
}

private struct ParityExpectation: Decodable {
    let error: Double?
    let scores: [ParityCandidateScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tiedIndices: [Int]
}

private struct ParityCandidateScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable, CustomStringConvertible {
    case excluded
    case score(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let score = try? container.decode(Double.self) {
            self = .score(score)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown parity score")
        }
    }

    var doubleValue: Double? {
        guard case .score(let value) = self else { return nil }
        return value
    }

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .score(let value): return String(value)
        }
    }
}

private extension Dictionary where Key == String, Value == Double {
    var lightingValues: [LightingCondition: Double] {
        compactMap { key, value in LightingCondition(rawValue: key).map { ($0, value) } }
            .reduce(into: [:]) { $0[$1.0] = $1.1 }
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
