import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the versioned golden vectors published by color_matching.
///
/// The fixture is copied verbatim from
/// `viamin/color_matching:priv/parity/v1/corpus.json` at commit
/// 47057afd58f7d46b4d4b740ca7d2d08947774471.
final class WeightedSquaredErrorParityTests: XCTestCase {
    func testCorpusMetadataDescribesTheSupportedSolverContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })
    }

    func testWeightedSquaredErrorAndSelectionMatchEveryCorpusScenario() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let weights = scenario.weights.channelWeights
            let target = scenario.target.targetResponseVector
            let palette = try scenario.palette.sortedByIndex().map(\.paletteColor)
            let results = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            assertScores(results, match: scenario.expected.scores, scenario: scenario.id)
            assertSelection(results, palette: palette, match: scenario.expected, scenario: scenario.id)
            try assertSolverSelectionWhenTargetIsComplete(
                target: scenario.target,
                palette: palette,
                weights: weights,
                expected: scenario.expected,
                scenario: scenario.id
            )
        }
    }

    private func assertScores(
        _ results: [ScorerResult],
        match expectedScores: [ParityExpectedScore],
        scenario: String
    ) {
        XCTAssertEqual(results.count, expectedScores.count, "\(scenario): score count")
        for (result, expectedScore) in zip(results, expectedScores.sorted { $0.index < $1.index }) {
            switch (result, expectedScore.score) {
            case (.excluded, .excluded):
                continue
            case (.score(let actual), .value(let expected)):
                XCTAssertEqual(actual, expected, "\(scenario): score at index \(expectedScore.index)")
            default:
                XCTFail("\(scenario): score at index \(expectedScore.index) did not match exclusion policy")
            }
        }
    }

    private func assertSelection(
        _ results: [ScorerResult],
        palette: [PaletteColor],
        match expected: ParityExpected,
        scenario: String
    ) {
        let scored = results.enumerated().compactMap { index, result -> (Int, Double)? in
            guard case .score(let value) = result else { return nil }
            return (index, value)
        }
        let selected = earliestBest(in: scored)

        XCTAssertEqual(selected?.0, expected.selectedIndex, "\(scenario): selected index")
        XCTAssertEqual(selected.map { palette[$0.0].hex }, expected.selectedHexColor, "\(scenario): selected color")
        XCTAssertEqual(selected?.1, expected.error, "\(scenario): selected error")

        let ties = scored.filter { $0.1 == expected.error }.map(\.0)
        XCTAssertEqual(ties, expected.tiedIndices, "\(scenario): tied indices")
        XCTAssertEqual(expected.tieBroke, ties.isEmpty ? nil : ties.count > 1, "\(scenario): tie-break marker")
        if let selected {
            XCTAssertEqual(selected.0, ties.first, "\(scenario): earliest tied candidate wins")
        }
    }

    private func assertSolverSelectionWhenTargetIsComplete(
        target: ParityVector,
        palette: [PaletteColor],
        weights: ChannelWeights,
        expected: ParityExpected,
        scenario: String
    ) throws {
        let active = weights.activeEntries.map(\.condition)
        guard active.allSatisfy({ target.channels[$0.rawValue] != nil }) else { return }

        let sourceGrids = Dictionary(uniqueKeysWithValues: active.map {
            ($0, BrightnessGrid(width: 1, height: 1, values: [target.channels[$0.rawValue]!]))
        })
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: sourceGrids, weights: weights)

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), expected.selectedIndex, "\(scenario): solver selection")
        if let expectedError = expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, "\(scenario): solver error")
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, "\(scenario): unmatched solver error")
        }
    }

    private func earliestBest(in scored: [(Int, Double)]) -> (Int, Double)? {
        var best: (Int, Double)?
        for candidate in scored where candidate.1 < (best?.1 ?? .infinity) {
            best = candidate
        }
        return best
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scenarios: [ParityScenario]
    let scorer: String
    let selection: String
}

private struct ParityScenario: Decodable {
    let expected: ParityExpected
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: ParityWeights
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityExpectedScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else {
            guard try container.decode(String.self) == "excluded" else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown parity score")
            }
            self = .excluded
        }
    }
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?

    var targetResponseVector: TargetResponseVector {
        TargetResponseVector(Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        }))
    }

    var paletteColor: PaletteColor {
        PaletteColor(
            id: index ?? -1,
            hex: hexColor,
            rgb: RGBColor(hex: hexColor)!,
            responses: Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
                LightingCondition(rawValue: key).map { ($0, IlluminationResponse(brightness: value)) }
            })
        )
    }
}

private struct ParityWeights: Decodable {
    let blue: Double?
    let green: Double?
    let lps: Double?
    let red: Double?
    let white: Double?

    var channelWeights: ChannelWeights {
        ChannelWeights(
            white: white ?? 0,
            red: red ?? 0,
            green: green ?? 0,
            blue: blue ?? 0,
            lps: lps ?? 0
        )
    }
}

private extension Array where Element == ParityVector {
    func sortedByIndex() throws -> [ParityVector] {
        let sorted = try sorted { lhs, rhs in
            guard let lhsIndex = lhs.index, let rhsIndex = rhs.index else {
                throw ParityCorpusError.missingPaletteIndex
            }
            return lhsIndex < rhsIndex
        }
        let expectedIndices = sorted.indices.map { Optional($0) }
        guard sorted.map(\.index) == expectedIndices else {
            throw ParityCorpusError.nonContiguousPaletteIndices
        }
        return sorted
    }
}

private enum ParityCorpusError: Error {
    case missingPaletteIndex
    case nonContiguousPaletteIndices
}
