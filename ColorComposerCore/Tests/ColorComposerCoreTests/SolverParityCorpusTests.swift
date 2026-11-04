import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testCorpusDeclaresTheWeightedSquaredErrorContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
        XCTAssertFalse(corpus.scenarios.isEmpty)
    }

    func testWeightedSquaredErrorScorerAndDefaultSolverMatchEveryCorpusScenario() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()
        let solver = CompositionSolver()

        for scenario in corpus.scenarios {
            let palette = try scenario.palette.map(makePaletteColor)
            let target = makeTarget(from: scenario.target)
            let weights = makeWeights(from: scenario.weights)

            XCTAssertEqual(
                scenario.palette.compactMap(\.index),
                Array(scenario.palette.indices),
                "Corpus palette ordering changed for scenario \\(scenario.id)"
            )

            for expectedScore in scenario.expected.scores {
                let actual = scorer.score(
                    candidate: palette[expectedScore.index],
                    target: target,
                    weights: weights
                )
                assertScore(
                    actual,
                    matches: expectedScore.score,
                    scenarioID: scenario.id,
                    candidateIndex: expectedScore.index
                )
            }

            guard let expectedIndex = scenario.expected.selectedIndex,
                  let expectedError = scenario.expected.error,
                  let sourceGrids = sourceGrids(for: target, weights: weights)
            else {
                XCTAssertTrue(
                    scenario.expected.scores.allSatisfy { $0.score == .excluded },
                    "Only all-excluded scenarios may omit a solver selection (\\(scenario.id))."
                )
                continue
            }

            let result = try solver.solve(
                palette: palette,
                sourceGrids: sourceGrids,
                weights: weights
            )

            XCTAssertEqual(result.colorIndices, [expectedIndex], "Scenario \\(scenario.id)")
            XCTAssertEqual(result.errors, [expectedError], "Scenario \\(scenario.id)")
            XCTAssertEqual(result.palette[expectedIndex].hex, scenario.expected.selectedHexColor)
            XCTAssertEqual(
                result.excludedCandidateCount,
                scenario.expected.scores.filter { $0.score == .excluded }.count,
                "Scenario \\(scenario.id)"
            )

            let tiedIndices = scenario.expected.scores.compactMap { score -> Int? in
                guard score.score == .value(expectedError) else { return nil }
                return score.index
            }
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, "Scenario \\(scenario.id)")
            XCTAssertEqual(scenario.expected.tieBroke, tiedIndices.count > 1, "Scenario \\(scenario.id)")
            XCTAssertEqual(expectedIndex, tiedIndices.first, "Scenario \\(scenario.id)")
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parity-v1-corpus.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makePaletteColor(_ vector: ParityVector) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: vector.hexColor), "Invalid corpus hex color \\(vector.hexColor)")
        let responses = vector.channels.reduce(into: [LightingCondition: IlluminationResponse]()) { result, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            result[condition] = IlluminationResponse(brightness: entry.value)
        }
        return PaletteColor(
            id: try XCTUnwrap(vector.index, "Palette vector is missing its index"),
            hex: vector.hexColor,
            rgb: rgb,
            responses: responses
        )
    }

    private func makeTarget(from vector: ParityVector) -> TargetResponseVector {
        let brightness = vector.channels.reduce(into: [LightingCondition: Double]()) { result, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            result[condition] = entry.value
        }
        return TargetResponseVector(brightness)
    }

    private func makeWeights(from rawWeights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: rawWeights[LightingCondition.white.rawValue] ?? 0,
            red: rawWeights[LightingCondition.red.rawValue] ?? 0,
            green: rawWeights[LightingCondition.green.rawValue] ?? 0,
            blue: rawWeights[LightingCondition.blue.rawValue] ?? 0,
            lps: rawWeights[LightingCondition.lps.rawValue] ?? 0
        )
    }

    private func sourceGrids(
        for target: TargetResponseVector,
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid]? {
        let entries = weights.activeConditions.compactMap { condition -> (LightingCondition, BrightnessGrid)? in
            guard let brightness = target.value(for: condition) else { return nil }
            return (condition, BrightnessGrid(width: 1, height: 1, values: [brightness]))
        }
        guard entries.count == weights.activeConditions.count else { return nil }
        return Dictionary(uniqueKeysWithValues: entries)
    }

    private func assertScore(
        _ actual: ScorerResult,
        matches expected: ParityScore,
        scenarioID: String,
        candidateIndex: Int
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actualValue), .value(let expectedValue)):
            XCTAssertEqual(actualValue, expectedValue, "Scenario \\(scenarioID), candidate \\(candidateIndex)")
        default:
            XCTFail("Scenario \\(scenarioID), candidate \\(candidateIndex): expected \\(expected), got \\(actual)")
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?

    private enum CodingKeys: String, CodingKey {
        case channels
        case hexColor = "hex_color"
        case index
    }
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]

    private enum CodingKeys: String, CodingKey {
        case error
        case scores
        case selectedHexColor = "selected_hex_color"
        case selectedIndex = "selected_index"
        case tieBroke = "tie_broke"
        case tiedIndices = "tied_indices"
    }
}

private struct ParityExpectedScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable, Equatable, CustomStringConvertible {
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
            return
        }
        guard try container.decode(String.self) == "excluded" else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected score or excluded")
        }
        self = .excluded
    }
}
