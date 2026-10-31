import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    private static let corpusURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")

    func testWeightedSquaredErrorMatchesPublishedParityCorpus() throws {
        guard FileManager.default.fileExists(atPath: Self.corpusURL.path) else {
            return XCTFail(
                "Vendor the published corpus at \(Self.corpusURL.path); see docs/issue-39-verification-plan.md."
            )
        }
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let palette = try scenario.palette.map(makePaletteColor)
            let target = try targetVector(from: scenario.target.channels)
            let weights = try makeWeights(from: scenario.weights)

            for expectedScore in scenario.expected.scores {
                let actual = scorer.score(
                    candidate: palette[expectedScore.index],
                    target: target,
                    weights: weights
                )
                assertScore(actual, equals: expectedScore.score, scenarioID: scenario.id)
            }

            if scenario.expected.error != nil {
                let result = try CompositionSolver().solve(
                    palette: palette,
                    sourceGrids: sourceGrids(target: target, weights: weights),
                    weights: weights
                )
                XCTAssertEqual(result.colorIndices, [scenario.expected.selectedIndex], scenario.id)
                assertError(result.errors[0], equals: scenario.expected.error, scenarioID: scenario.id)
            }

            if scenario.expected.tieBroke == true {
                XCTAssertEqual(scenario.expected.selectedIndex, scenario.expected.tiedIndices.min(), scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let data = try Data(contentsOf: Self.corpusURL)
        return try JSONDecoder().decode(ParityCorpus.self, from: data)
    }

    private func makePaletteColor(_ fixture: CandidateFixture) throws -> PaletteColor {
        PaletteColor(
            id: try XCTUnwrap(fixture.index),
            hex: fixture.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: fixture.hexColor)),
            responses: try responses(from: fixture.channels)
        )
    }

    private func targetVector(from channels: [String: Double]) throws -> TargetResponseVector {
        TargetResponseVector(try conditions(from: channels))
    }

    private func makeWeights(from weights: [String: Double]) throws -> ChannelWeights {
        let conditions = try conditions(from: weights)
        return ChannelWeights(
            white: conditions[.white] ?? 0,
            red: conditions[.red] ?? 0,
            green: conditions[.green] ?? 0,
            blue: conditions[.blue] ?? 0,
            lps: conditions[.lps] ?? 0
        )
    }

    private func sourceGrids(target: TargetResponseVector, weights: ChannelWeights) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, fill: target.value(for: condition) ?? 0))
        })
    }

    private func responses(from channels: [String: Double]) throws -> [LightingCondition: IlluminationResponse] {
        try conditions(from: channels).mapValues { IlluminationResponse(brightness: $0) }
    }

    private func conditions(from values: [String: Double]) throws -> [LightingCondition: Double] {
        try values.reduce(into: [:]) { result, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else {
                // The corpus deliberately includes unknown weights; they are not
                // part of the Swift solver's supported condition set.
                return
            }
            result[condition] = entry.value
        }
    }

    private func assertScore(
        _ actual: ScorerResult,
        equals expected: ScoreFixture,
        scenarioID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .value(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, scenarioID, file: file, line: line)
        default:
            XCTFail("\(scenarioID): expected \(expected), got \(actual)", file: file, line: line)
        }
    }

    private func assertError(
        _ actual: Double,
        equals expected: Double?,
        scenarioID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let expected else {
            XCTAssertEqual(actual, .infinity, scenarioID, file: file, line: line)
            return
        }
        XCTAssertEqual(actual, expected, accuracy: 1e-12, scenarioID, file: file, line: line)
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [ScenarioFixture]
    let scorer: String
    let selection: String
}

private struct ScenarioFixture: Decodable {
    let expected: ExpectedFixture
    let id: String
    let palette: [CandidateFixture]
    let target: CandidateFixture
    let weights: [String: Double]
}

private struct CandidateFixture: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ExpectedFixture: Decodable {
    let error: Double?
    let scores: [ExpectedScoreFixture]
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ExpectedScoreFixture: Decodable {
    let index: Int
    let score: ScoreFixture
}

private enum ScoreFixture: Decodable, CustomStringConvertible {
    case excluded
    case value(Double)

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

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .value(let value): return String(value)
        }
    }
}
