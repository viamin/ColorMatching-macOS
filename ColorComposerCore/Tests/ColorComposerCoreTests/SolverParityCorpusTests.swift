import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testCorpusMetadataAndScenariosReplayExactly() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertFalse(corpus.scenarios.isEmpty)
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: ParityScenario) throws {
        let palette = scenario.palette
            .sorted { $0.index < $1.index }
            .map(makePaletteColor)
        let target = TargetResponseVector(responses: scenario.target.channels)
        let weights = ChannelWeights(channels: scenario.weights)
        let scorer = WeightedSquaredErrorScorer()
        let expectedScores = Dictionary(uniqueKeysWithValues: scenario.expected.scores.map { ($0.index, $0.result) })

        for (index, candidate) in palette.enumerated() {
            let expectedScore = try XCTUnwrap(expectedScores[index], "\(scenario.id): missing expected score at \(index)")
            XCTAssertEqual(
                scorer.score(candidate: candidate, target: target, weights: weights),
                expectedScore.scorerResult,
                "\(scenario.id): score at palette index \(index)"
            )
        }

        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: sourceGrids(for: scenario.target.channels, weights: weights),
            weights: weights
        )

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
        if let expectedError = scenario.expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, scenario.id)
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
        }
        XCTAssertEqual(tiedIndices(in: expectedScores, selectedError: scenario.expected.error), scenario.expected.tiedIndices)
    }

    private func loadCorpus() throws -> ParityCorpus {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = directory.appendingPathComponent("Fixtures/weighted_squared_error_parity_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makePaletteColor(_ vector: ParityVector) -> PaletteColor {
        let responses = vector.channels.mapValues { IlluminationResponse(brightness: $0) }
        return PaletteColor(id: vector.index ?? -1, hex: vector.hexColor, rgb: RGBColor(hex: vector.hexColor)!, responses: responses)
    }

    private func sourceGrids(
        for channels: [LightingCondition: Double],
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, fill: channels[condition]!))
        })
    }

    private func tiedIndices(
        in scores: [Int: ParityScoreValue],
        selectedError: Double?
    ) -> [Int] {
        guard let selectedError else { return [] }
        return scores.compactMap { index, score in
            score == .score(selectedError) ? index : nil
        }.sorted()
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [LightingCondition: Double]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [LightingCondition: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ParityScoreValue

    var result: ParityScoreValue { score }
}

private extension TargetResponseVector {
    init(responses: [LightingCondition: Double]) {
        self.init(responses)
    }
}

private extension ChannelWeights {
    init(channels: [LightingCondition: Double]) {
        self.init(
            white: channels[.white] ?? 0,
            red: channels[.red] ?? 0,
            green: channels[.green] ?? 0,
            blue: channels[.blue] ?? 0,
            lps: channels[.lps] ?? 0
        )
    }
}

private enum ParityScoreValue: Decodable, Equatable {
    case score(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let score = try? container.decode(Double.self) {
            self = .score(score)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }

    var scorerResult: ScorerResult {
        switch self {
        case .score(let value): return .score(value)
        case .excluded: return .excluded
        }
    }
}
