import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    private let scorer = WeightedSquaredErrorScorer()

    func testCorpusMetadataDescribesTheSharedSolverContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })
    }

    func testWeightedSquaredErrorScorerReplaysEveryParityScenarioExactly() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: SolverParityScenario) throws {
        let weights = channelWeights(from: scenario.weights)
        let target = targetVector(from: scenario.target)
        let palette = try scenario.palette.sorted { $0.index < $1.index }.map { try makeColor($0) }
        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
        let expectedScores = scenario.expected.scores.sorted { $0.index < $1.index }.map(\.score)

        XCTAssertEqual(actualScores, expectedScores, "\(scenario.id): score table")
        assertSelection(scenario, palette: palette, scores: actualScores)
        try assertSolverSelection(scenario, palette: palette, weights: weights)
    }

    private func assertSelection(
        _ scenario: SolverParityScenario,
        palette: [PaletteColor],
        scores: [ScorerResult]
    ) {
        let expected = scenario.expected
        let selected = earliestLowestScore(in: scores)

        XCTAssertEqual(selected?.index, expected.selectedIndex, "\(scenario.id): selected index")
        XCTAssertEqual(selected?.score, expected.error, "\(scenario.id): selected error")
        XCTAssertEqual(selected.map { palette[$0.index].hex }, expected.selectedHexColor, "\(scenario.id): selected color")

        guard let selected else {
            XCTAssertNil(expected.tieBroke, "\(scenario.id): an empty selection has no tie state")
            XCTAssertEqual(expected.tiedIndices, [], "\(scenario.id): an empty selection has no ties")
            return
        }

        let tiedIndices = scores.enumerated().compactMap { index, result -> Int? in
            guard case .score(let score) = result, score == selected.score else { return nil }
            return index
        }
        XCTAssertEqual(tiedIndices, expected.tiedIndices, "\(scenario.id): tied indices")
        XCTAssertEqual(expected.tieBroke, tiedIndices.count > 1, "\(scenario.id): tie evidence")
    }

    private func assertSolverSelection(
        _ scenario: SolverParityScenario,
        palette: [PaletteColor],
        weights: ChannelWeights
    ) throws {
        let activeConditions = weights.activeConditions
        guard activeConditions.allSatisfy({ scenario.target.channels[wireName(for: $0)] != nil }) else {
            return
        }

        let sourceGrids = Dictionary(uniqueKeysWithValues: activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, fill: scenario.target.channels[wireName(for: condition)]!))
        })
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: sourceGrids, weights: weights)

        XCTAssertEqual(result.colorIndices, [scenario.expected.selectedIndex], "\(scenario.id): solver selection")
        XCTAssertEqual(result.errors, [scenario.expected.error ?? .infinity], "\(scenario.id): solver error")
    }

    private func earliestLowestScore(in scores: [ScorerResult]) -> (index: Int, score: Double)? {
        var best: (index: Int, score: Double)?
        for (index, result) in scores.enumerated() {
            guard case .score(let score) = result else { continue }
            if best == nil || score < best!.score {
                best = (index, score)
            }
        }
        return best
    }

    private func makeColor(_ vector: SolverParityVector) throws -> PaletteColor {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (name, brightness) in vector.channels {
            if let condition = condition(named: name) {
                responses[condition] = IlluminationResponse(brightness: brightness)
            }
        }
        return PaletteColor(
            id: vector.index ?? 0,
            hex: vector.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: vector.hexColor)),
            responses: responses
        )
    }

    private func targetVector(from vector: SolverParityVector) -> TargetResponseVector {
        TargetResponseVector(
            Dictionary(uniqueKeysWithValues: vector.channels.compactMap { name, brightness in
                condition(named: name).map { ($0, brightness) }
            })
        )
    }

    private func channelWeights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func condition(named name: String) -> LightingCondition? {
        LightingCondition.all.first { wireName(for: $0) == name }
    }

    private func wireName(for condition: LightingCondition) -> String {
        switch condition {
        case .white: "white"
        case .red: "red"
        case .green: "green"
        case .blue: "blue"
        case .lps: "lps"
        }
    }

    private func loadCorpus() throws -> SolverParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SolverParityCorpus.self, from: Data(contentsOf: fixture))
    }
}

private struct SolverParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
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
    let scores: [SolverParityIndexedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct SolverParityIndexedScore: Decodable {
    let index: Int
    let score: ScorerResult
}

extension ScorerResult: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let score = try? container.decode(Double.self) {
            self = .score(score)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }
}
