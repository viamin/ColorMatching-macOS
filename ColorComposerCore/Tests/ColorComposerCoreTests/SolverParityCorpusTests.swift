import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testCorpusMetadataDeclaresTheSharedSolverContract() throws {
        let corpus = try decodeCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
        XCTAssertFalse(corpus.scenarios.filter { $0.expected.tieBroke == true }.isEmpty)
        XCTAssertFalse(corpus.scenarios.filter { $0.expected.selectedIndex == nil }.isEmpty)
    }

    func testWeightedSquaredErrorReplaysCommittedParityCorpus() throws {
        let corpus = try decodeCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let target = makeTarget(from: scenario.target)
            let palette = try scenario.palette.map(makeColor)
            let weights = makeWeights(from: scenario.weights)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            assertScores(actualScores, match: scenario.expected.scores, scenarioID: scenario.id)
            try assertSelection(
                scenario.expected,
                palette: palette,
                target: scenario.target,
                weights: weights,
                scenarioID: scenario.id
            )
            assertTieEvidence(actualScores, expected: scenario.expected, scenarioID: scenario.id)
        }
    }

    private func decodeCorpus() throws -> SolverParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(SolverParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makeColor(_ vector: SolverParityVector) throws -> PaletteColor {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (rawCondition, brightness) in vector.channels {
            guard let condition = LightingCondition(rawValue: rawCondition) else { continue }
            responses[condition] = IlluminationResponse(brightness: brightness)
        }
        return PaletteColor(
            id: vector.index ?? 0,
            hex: vector.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: vector.hexColor)),
            responses: responses
        )
    }

    private func makeTarget(from vector: SolverParityVector) -> TargetResponseVector {
        TargetResponseVector(Dictionary(uniqueKeysWithValues: vector.channels.compactMap { rawCondition, brightness in
            LightingCondition(rawValue: rawCondition).map { ($0, brightness) }
        }))
    }

    private func makeWeights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func assertScores(
        _ actual: [ScorerResult],
        match expected: [SolverParityScore],
        scenarioID: String
    ) {
        XCTAssertEqual(actual.count, expected.count, scenarioID)
        for (result, expectedScore) in zip(actual, expected.sorted { $0.index < $1.index }) {
            switch (result, expectedScore.value) {
            case (.excluded, .excluded):
                continue
            case (.score(let actualScore), .score(let expectedScore)):
                XCTAssertEqual(actualScore, expectedScore, scenarioID)
            default:
                XCTFail("\(scenarioID): score exclusion mismatch")
            }
        }
    }

    private func assertSelection(
        _ expected: SolverParityExpected,
        palette: [PaletteColor],
        target: SolverParityVector,
        weights: ChannelWeights,
        scenarioID: String
    ) throws {
        guard let expectedIndex = expected.selectedIndex else {
            XCTAssertTrue(expected.scores.allSatisfy { $0.value == .excluded }, scenarioID)
            return
        }

        let sourceGrids = Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, fill: target.channels[condition.rawValue] ?? 0))
        })
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: sourceGrids,
            weights: weights
        )

        XCTAssertEqual(result.colorIndices, [expectedIndex], scenarioID)
        XCTAssertEqual(result.errors, [try XCTUnwrap(expected.error)], scenarioID)
        XCTAssertEqual(palette[expectedIndex].hex, expected.selectedHexColor, scenarioID)
    }

    private func assertTieEvidence(
        _ scores: [ScorerResult],
        expected: SolverParityExpected,
        scenarioID: String
    ) {
        guard let expectedError = expected.error else {
            XCTAssertNil(expected.tieBroke, scenarioID)
            XCTAssertEqual(expected.tiedIndices, [], scenarioID)
            return
        }
        let tiedIndices = scores.enumerated().compactMap { index, score in
            guard case .score(let value) = score, value == expectedError else { return nil }
            return index
        }

        XCTAssertEqual(tiedIndices, expected.tiedIndices, scenarioID)
        XCTAssertEqual(expected.tieBroke, tiedIndices.count > 1, scenarioID)
        XCTAssertEqual(tiedIndices.first, expected.selectedIndex, scenarioID)
    }
}

private struct SolverParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let scenarios: [SolverParityScenario]
    let scorer: String
    let selection: String
}

private struct SolverParityScenario: Decodable {
    let id: String
    let palette: [SolverParityVector]
    let target: SolverParityVector
    let weights: [String: Double]
    let expected: SolverParityExpected
}

private struct SolverParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct SolverParityExpected: Decodable {
    let error: Double?
    let scores: [SolverParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct SolverParityScore: Decodable {
    let index: Int
    let value: SolverParityScoreValue

    private enum CodingKeys: String, CodingKey {
        case index
        case value = "score"
    }
}

private enum SolverParityScoreValue: Decodable, Equatable {
    case excluded
    case score(Double)

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
}
