import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testCorpusMetadataAndScenarioCoverage() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertFalse(corpus.scenarios.isEmpty)
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true }, "Corpus must retain explicit tie cases.")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil }, "Corpus must retain no-selection cases.")
    }

    func testWeightedSquaredErrorScorerMatchesCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let target = TargetResponseVector(scenario.target.channels.lightingValues)
            let weights = scenario.weights.channelWeights
            let palette = scenario.palette.map(makePaletteColor)
            XCTAssertEqual(palette.count, scenario.expected.scores.count, "\(scenario.id): score table size")
            let scored = zip(palette, scenario.expected.scores.sorted { $0.index < $1.index }).map { candidate, expected in
                (scorer.score(candidate: candidate, target: target, weights: weights), expected)
            }

            for (actual, expected) in scored {
                assertScore(actual, matches: expected, scenarioID: scenario.id)
            }

            assertSelection(
                scored: scored,
                expected: scenario.expected,
                palette: palette,
                scenarioID: scenario.id
            )
            try assertSolverSelection(
                palette: palette,
                target: target,
                weights: weights,
                expected: scenario.expected,
                scenarioID: scenario.id
            )
        }
    }

    private func assertScore(
        _ actual: ScorerResult,
        matches expected: ParityCorpus.Score,
        scenarioID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (actual, expected.value) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .number(let expectedScore)):
            XCTAssertEqual(actual, expectedScore, accuracy: 0, "\(scenarioID), candidate \(expected.index)", file: file, line: line)
        default:
            XCTFail("\(scenarioID), candidate \(expected.index): expected \(expected.value), got \(actual)", file: file, line: line)
        }
    }

    private func assertSelection(
        scored: [(ScorerResult, ParityCorpus.Score)],
        expected: ParityCorpus.Expected,
        palette: [PaletteColor],
        scenarioID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let rankable = scored.compactMap { actual, score -> (Int, Double)? in
            guard case .score(let value) = actual else { return nil }
            return (score.index, value)
        }
        let minimum = rankable.map(\.1).min()
        let tiedIndices = minimum.map { minimum in
            rankable.compactMap { index, score in score == minimum ? index : nil }
        } ?? []

        XCTAssertEqual(tiedIndices, expected.tiedIndices, "\(scenarioID): tied indices", file: file, line: line)
        XCTAssertEqual(expected.tieBroke, tiedIndices.count > 1 ? true : (minimum == nil ? nil : false), "\(scenarioID): tie evidence", file: file, line: line)

        guard let selectedIndex = expected.selectedIndex else {
            XCTAssertNil(minimum, "\(scenarioID): expected no selected candidate", file: file, line: line)
            return
        }

        XCTAssertEqual(tiedIndices.first, selectedIndex, "\(scenarioID): earliest tied candidate must win", file: file, line: line)
        XCTAssertEqual(palette[selectedIndex].hex, expected.selectedHexColor, "\(scenarioID): selected color", file: file, line: line)
        XCTAssertEqual(minimum, expected.error, "\(scenarioID): selected error", file: file, line: line)
    }

    private func assertSolverSelection(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights,
        expected: ParityCorpus.Expected,
        scenarioID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let active = weights.activeEntries
        guard active.allSatisfy({ target.value(for: $0.condition) != nil }) else {
            return
        }
        let grids = Dictionary(uniqueKeysWithValues: active.map { entry in
            (entry.condition, BrightnessGrid(width: 1, height: 1, values: [target.value(for: entry.condition)!]))
        })
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), expected.selectedIndex, "\(scenarioID): solver selection", file: file, line: line)
        if let expectedError = expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 0, "\(scenarioID): solver error", file: file, line: line)
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, "\(scenarioID): unmatched solver error", file: file, line: line)
        }
    }

    private func makePaletteColor(_ entry: ParityCorpus.Vector) -> PaletteColor {
        PaletteColor(
            id: entry.index ?? -1,
            hex: entry.hexColor,
            rgb: RGBColor(hex: entry.hexColor)!,
            responses: entry.channels.lightingValues.mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func loadCorpus() throws -> ParityCorpus {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let fixture = sourceFile.deletingLastPathComponent().appendingPathComponent("Fixtures/corpus.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
    let scenarios: [Scenario]

    struct Scenario: Decodable {
        let id: String
        let weights: [String: Double]
        let target: Vector
        let palette: [Vector]
        let expected: Expected
    }

    struct Vector: Decodable {
        let index: Int?
        let hexColor: String
        let channels: [String: Double]
    }

    struct Expected: Decodable {
        let error: Double?
        let scores: [Score]
        let selectedHexColor: String?
        let selectedIndex: Int?
        let tieBroke: Bool?
        let tiedIndices: [Int]
    }

    struct Score: Decodable {
        enum Value: Decodable, CustomStringConvertible {
            case excluded
            case number(Double)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let value = try? container.decode(Double.self) {
                    self = .number(value)
                } else if try container.decode(String.self) == "excluded" {
                    self = .excluded
                } else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded.")
                }
            }

            var description: String {
                switch self {
                case .excluded: return "excluded"
                case .number(let value): return String(value)
                }
            }
        }

        let index: Int
        let value: Value

        private enum CodingKeys: String, CodingKey {
            case index
            case value = "score"
        }
    }
}

private extension Dictionary where Key == String, Value == Double {
    var lightingValues: [LightingCondition: Double] {
        reduce(into: [:]) { values, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            values[condition] = entry.value
        }
    }

    var channelWeights: ChannelWeights {
        ChannelWeights(
            white: self["white"] ?? 0,
            red: self["red"] ?? 0,
            green: self["green"] ?? 0,
            blue: self["blue"] ?? 0,
            lps: self["lps"] ?? 0
        )
    }
}
