import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    private static let corpusURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/weighted-squared-error-v1.json")

    func testCommittedParityCorpusMetadataAndRequiredCoverage() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertFalse(corpus.scenarios.isEmpty)
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })
    }

    func testWeightedSquaredErrorAndSolverMatchEveryCorpusScenarioExactly() throws {
        for scenario in try loadCorpus().scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: Scenario, file: StaticString = #filePath, line: UInt = #line) throws {
        let weights = scenario.weights.channelWeights
        let target = TargetResponseVector(scenario.target.channels.lightingValues)
        let palette = try scenario.palette.map { try $0.paletteColor() }
        let scorer = WeightedSquaredErrorScorer()

        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
        XCTAssertEqual(scenario.palette.map(\.index), scenario.expected.scores.map(\.index), scenario.id, file: file, line: line)
        XCTAssertEqual(actualScores, scenario.expected.scores.map(\.scorerResult), scenario.id, file: file, line: line)

        let sourceGrids = try sourceGrids(for: scenario.target.channels, weights: weights)
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: sourceGrids, weights: weights)
        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id, file: file, line: line)

        if let expectedError = scenario.expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, scenario.id, file: file, line: line)
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id, file: file, line: line)
        }

        let tiedIndices = scenario.expected.error.map { expectedError in
            actualScores.enumerated().compactMap { index, result in
                result == .score(expectedError) ? index : nil
            }
        } ?? []
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id, file: file, line: line)
        XCTAssertEqual(tiedIndices.count > 1, scenario.expected.tieBroke ?? false, scenario.id, file: file, line: line)
    }

    private func loadCorpus() throws -> Corpus {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Corpus.self, from: Data(contentsOf: Self.corpusURL))
    }

    private func sourceGrids(for channels: Channels, weights: ChannelWeights) throws -> [LightingCondition: BrightnessGrid] {
        try Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            guard let value = channels.value(for: condition) else {
                throw ParityFixtureError.missingTargetChannel(condition)
            }
            return (condition, BrightnessGrid(width: 1, height: 1, values: [value]))
        })
    }
}

private enum ParityFixtureError: Error, LocalizedError {
    case invalidHex(String)
    case missingTargetChannel(LightingCondition)

    var errorDescription: String? {
        switch self {
        case .invalidHex(let value): return "Invalid corpus color: \(value)"
        case .missingTargetChannel(let condition): return "Missing target channel: \(condition.rawValue)"
        }
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scenarios: [Scenario]
    let scorer: String
    let selection: String
}

private struct Scenario: Decodable {
    let expected: Expected
    let id: String
    let palette: [Vector]
    let target: Vector
    let weights: Channels
}

private struct Expected: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ExpectedScore: Decodable {
    let index: Int
    let score: Score
}

private enum Score: Decodable {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }

    var scorerResult: ScorerResult {
        switch self {
        case .excluded: return .excluded
        case .value(let value): return .score(value)
        }
    }
}

private struct Vector: Decodable {
    let channels: Channels
    let hexColor: String
    let index: Int?

    func paletteColor() throws -> PaletteColor {
        guard let rgb = RGBColor(hex: hexColor) else { throw ParityFixtureError.invalidHex(hexColor) }
        return PaletteColor(
            id: index ?? -1,
            hex: hexColor,
            rgb: rgb,
            responses: channels.lightingValues.mapValues(IlluminationResponse.init(brightness:))
        )
    }
}

private struct Channels: Decodable {
    let white: Double?
    let red: Double?
    let green: Double?
    let blue: Double?
    let lps: Double?

    var channelWeights: ChannelWeights {
        ChannelWeights(white: white ?? 0, red: red ?? 0, green: green ?? 0, blue: blue ?? 0, lps: lps ?? 0)
    }

    var lightingValues: [LightingCondition: Double] {
        LightingCondition.all.reduce(into: [:]) { values, condition in
            if let value = value(for: condition) { values[condition] = value }
        }
    }

    func value(for condition: LightingCondition) -> Double? {
        switch condition {
        case .white: return white
        case .red: return red
        case .green: return green
        case .blue: return blue
        case .lps: return lps
        }
    }
}
