import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testMatchesCommittedColorMatchingParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let weights = ChannelWeights(channels: scenario.weights)
        let target = TargetResponseVector(channels: scenario.target.channels)
        let palette = try scenario.palette.map(PaletteColor.init(parityColor:))
        let scorer = WeightedSquaredErrorScorer()
        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
        for (actual, expected) in zip(actualScores, scenario.expected.scores) {
            assertScore(actual, equals: expected.score, scenarioID: scenario.id, candidateIndex: expected.index)
        }

        let rankedIndices: [Int]
        if let expectedError = scenario.expected.error {
            rankedIndices = actualScores.enumerated().compactMap { index, result -> Int? in
                guard case .score(let score) = result, score == expectedError else { return nil }
                return index
            }
        } else {
            rankedIndices = []
        }
        XCTAssertEqual(rankedIndices, scenario.expected.tiedIndices, scenario.id)

        let selectedIndex = try selectedIndex(
            palette: palette,
            target: scenario.target.channels,
            weights: weights,
            scores: actualScores
        )
        XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, scenario.id)
        XCTAssertEqual(selectedIndex.map { palette[$0].hex }, scenario.expected.selectedHexColor, scenario.id)

        if let selectedIndex, let expectedError = scenario.expected.error {
            guard case .score(let selectedScore) = actualScores[selectedIndex] else {
                return XCTFail("\(scenario.id): selected candidate was excluded")
            }
            XCTAssertEqual(selectedScore, expectedError, accuracy: 1e-12, scenario.id)
        } else {
            XCTAssertNil(scenario.expected.error, scenario.id)
        }

        if scenario.expected.tieBroke == true {
            XCTAssertEqual(selectedIndex, scenario.expected.tiedIndices.first, scenario.id)
        }
    }

    private func selectedIndex(
        palette: [PaletteColor],
        target: [String: Double],
        weights: ChannelWeights,
        scores: [ScorerResult]
    ) throws -> Int? {
        let activeConditions = weights.activeConditions
        guard activeConditions.allSatisfy({ target[$0.rawValue] != nil }) else {
            return scores.enumerated().first(where: { if case .score = $0.element { true } else { false } })?.offset
        }

        let sourceGrids = Dictionary(uniqueKeysWithValues: activeConditions.map {
            ($0, BrightnessGrid(width: 1, height: 1, values: [target[$0.rawValue]!]))
        })
        return try CompositionSolver().solve(
            palette: palette,
            sourceGrids: sourceGrids,
            weights: weights
        ).colorIndex(x: 0, y: 0)
    }

    private func assertScore(
        _ actual: ScorerResult,
        equals expected: ParityScore,
        scenarioID: String,
        candidateIndex: Int
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "\(scenarioID), candidate \(candidateIndex)")
        default:
            XCTFail("\(scenarioID), candidate \(candidateIndex): expected \(expected), got \(actual)")
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = directory.appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
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
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpectation: Decodable {
    let error: Double?
    let scores: [ParityCandidateScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityCandidateScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable, CustomStringConvertible {
    case score(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .score(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }

    var description: String {
        switch self {
        case .score(let value): return "score(\(value))"
        case .excluded: return "excluded"
        }
    }
}

private extension ChannelWeights {
    init(channels: [String: Double]) {
        self.init(
            white: channels[LightingCondition.white.rawValue] ?? 0,
            red: channels[LightingCondition.red.rawValue] ?? 0,
            green: channels[LightingCondition.green.rawValue] ?? 0,
            blue: channels[LightingCondition.blue.rawValue] ?? 0,
            lps: channels[LightingCondition.lps.rawValue] ?? 0
        )
    }
}

private extension TargetResponseVector {
    init(channels: [String: Double]) {
        self.init(Dictionary(uniqueKeysWithValues: LightingCondition.all.compactMap { condition in
            channels[condition.rawValue].map { (condition, $0) }
        }))
    }
}

private extension PaletteColor {
    init(parityColor color: ParityColor) throws {
        guard let rgb = RGBColor(hex: color.hexColor) else {
            throw ParityFixtureError.invalidHex(color.hexColor)
        }
        let responses = Dictionary(uniqueKeysWithValues: LightingCondition.all.compactMap { condition in
            color.channels[condition.rawValue].map { (condition, IlluminationResponse(brightness: $0)) }
        })
        self.init(id: color.index ?? -1, hex: color.hexColor, rgb: rgb, responses: responses)
    }
}

private enum ParityFixtureError: Error {
    case invalidHex(String)
}
