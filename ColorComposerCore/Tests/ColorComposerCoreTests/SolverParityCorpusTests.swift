import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the solver-parity golden corpus committed by the `color_matching`
/// server (viamin/color_matching#111) through `WeightedSquaredErrorScorer` and
/// asserts exact agreement with the Elixir `WeightedSquaredError` +
/// `IlluminantMatching.best_match/3` results: per-candidate scores, missing-
/// measurement exclusion, selection, and earliest-index tie-breaking.
///
/// The corpus fixture is copied verbatim from the server repo's
/// `priv/parity/v1/corpus.json` (generated with `mix parity.generate`).
/// See `docs/solver-parity-corpus.md` for the schema and refresh steps.
final class SolverParityCorpusTests: XCTestCase {
    private static let fixturesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ParityCorpus", isDirectory: true)

    private enum CorpusError: Error, CustomStringConvertible {
        case unparseableHex(scenario: String, hex: String)

        var description: String {
            switch self {
            case let .unparseableHex(scenario, hex):
                return "Scenario \(scenario): unparseable hex color \(hex)"
            }
        }
    }

    private struct Corpus: Decodable {
        let algorithm_version: Int
        let scorer: String
        let selection: String
        let missing_policy: String
        let light_sources: [String]
        let scenarios: [Scenario]
    }

    private struct Scenario: Decodable {
        let id: String
        let description: String?
        let weights: [String: Double]
        let target: VectorEntry
        let palette: [VectorEntry]
        let expected: Expected
    }

    private struct VectorEntry: Decodable {
        let index: Int?
        let hex_color: String
        let channels: [String: Double]
    }

    private struct Expected: Decodable {
        struct CandidateScore: Decodable {
            let index: Int
            let score: CorpusScore
        }

        let scores: [CandidateScore]
        let selected_index: Int?
        let selected_hex_color: String?
        let error: Double?
        let tie_broke: Bool?
        let tied_indices: [Int]
    }

    private enum CorpusScore: Decodable, Equatable {
        case score(Double)
        case excluded

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                self = .score(value)
            } else if let value = try? container.decode(String.self), value == "excluded" {
                self = .excluded
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Corpus score must be a number or \"excluded\"."
                )
            }
        }
    }

    private struct Replay {
        let scores: [CorpusScore]
        let selection: Int?
        let selectedHexColor: String?
        let error: Double?
        let tiedIndices: [Int]

        var tieBroke: Bool { tiedIndices.count > 1 }
    }

    // MARK: - Corpus discovery

    private func loadCorpora() throws -> [Corpus] {
        let files = corpusFiles()
        return try files.map { url in
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Corpus.self, from: data)
        }
    }

    private func corpusFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Self.fixturesRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return contents
            .filter { $0.hasDirectoryPath }
            .map { $0.appendingPathComponent("corpus.json") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    // MARK: - Corpus stamp and coverage

    func testCorpusFixtureIsCommittedAndStamped() throws {
        let corpora = try loadCorpora()

        XCTAssertFalse(
            corpora.isEmpty,
            "Solver parity corpus fixture is missing from \(Self.fixturesRoot.path). " +
                "Copy priv/parity/v1/corpus.json from viamin/color_matching (see docs/solver-parity-corpus.md)."
        )

        for corpus in corpora {
            XCTAssertEqual(corpus.algorithm_version, 1, "Unsupported corpus algorithm version")
            XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
            XCTAssertEqual(corpus.selection, "earliest-index-wins")
            XCTAssertEqual(corpus.light_sources, ["white", "red", "green", "blue", "lps"])
            XCTAssertFalse(corpus.scenarios.isEmpty)
        }
    }

    func testCorpusCoversTiesExclusionsAndWeightHandling() throws {
        let scenarios = try loadCorpora().flatMap(\.scenarios)
        let ids = Set(scenarios.map(\.id))

        let required = [
            "tie-symmetric-around-target",
            "tie-duplicate-vectors",
            "tie-three-way-on-lps",
            "missing-candidate-excluded",
            "missing-target-excluded",
            "all-excluded",
            "zero-weight-channel-missing",
            "unknown-weight-ignored",
            "mixed-large-palette",
        ]
        for scenarioID in required {
            XCTAssertTrue(ids.contains(scenarioID), "Corpus lost coverage scenario \(scenarioID)")
        }

        XCTAssertTrue(scenarios.contains { $0.expected.tie_broke == true }, "Corpus lost tie cases")
        XCTAssertTrue(scenarios.contains { $0.expected.selected_index == nil }, "Corpus lost all-excluded cases")
        XCTAssertTrue(
            scenarios.contains { $0.expected.scores.contains { $0.score == .excluded } },
            "Corpus lost exclusion cases"
        )
    }

    // MARK: - Scenario replay

    func testReplaysEveryScenarioWithExactAgreement() throws {
        let corpora = try loadCorpora()
        XCTAssertFalse(corpora.isEmpty, "No corpus fixture to replay")

        for corpus in corpora {
            for scenario in corpus.scenarios {
                let replay = try replay(scenario)

                XCTAssertEqual(
                    replay.scores.count,
                    scenario.expected.scores.count,
                    "\(scenario.id): scored candidate count"
                )

                for expectedScore in scenario.expected.scores {
                    guard expectedScore.index < replay.scores.count else { continue }
                    let actual = replay.scores[expectedScore.index]
                    switch (actual, expectedScore.score) {
                    case (.excluded, .excluded):
                        break
                    case let (.score(actualValue), .score(expectedValue)):
                        XCTAssertEqual(
                            actualValue,
                            expectedValue,
                            accuracy: 1e-12,
                            "\(scenario.id): candidate \(expectedScore.index) score"
                        )
                    default:
                        XCTFail("\(scenario.id): candidate \(expectedScore.index) expected \(expectedScore.score), got \(actual)")
                    }
                }

                XCTAssertEqual(replay.selection, scenario.expected.selected_index, "\(scenario.id): selection")
                XCTAssertEqual(replay.selectedHexColor, scenario.expected.selected_hex_color, "\(scenario.id): selected hex color")

                switch (replay.error, scenario.expected.error) {
                case let (.some(actualError), .some(expectedError)):
                    XCTAssertEqual(actualError, expectedError, accuracy: 1e-12, "\(scenario.id): selected error")
                case (nil, nil):
                    break
                default:
                    XCTFail("\(scenario.id): expected error \(String(describing: scenario.expected.error)), got \(String(describing: replay.error))")
                }

                XCTAssertEqual(replay.tiedIndices, scenario.expected.tied_indices, "\(scenario.id): tied indices")
                XCTAssertEqual(replay.tieBroke, scenario.expected.tie_broke ?? false, "\(scenario.id): tie_broke")
            }
        }
    }

    // MARK: - Replay harness

    /// Scores every palette candidate with `WeightedSquaredErrorScorer` and
    /// applies the solver's selection policy: excluded candidates drop out,
    /// the strictly minimal score wins, and the earliest index wins an exact
    /// tie — mirroring `IlluminantMatching.best_match/3`.
    private func replay(_ scenario: Scenario) throws -> Replay {
        let scorer = WeightedSquaredErrorScorer()
        let weights = channelWeights(from: scenario.weights)
        let target = TargetResponseVector(brightness(from: scenario.target.channels))

        var palette: [PaletteColor] = []
        for (index, entry) in scenario.palette.enumerated() {
            guard let color = paletteColor(from: entry, index: index) else {
                throw CorpusError.unparseableHex(scenario: scenario.id, hex: entry.hex_color)
            }
            palette.append(color)
        }

        var scores: [CorpusScore] = []
        var eligible: [(index: Int, score: Double)] = []
        for (index, candidate) in palette.enumerated() {
            switch scorer.score(candidate: candidate, target: target, weights: weights) {
            case .excluded:
                scores.append(.excluded)
            case let .score(value):
                scores.append(.score(value))
                eligible.append((index, value))
            }
        }

        guard let minimum = eligible.map(\.score).min() else {
            return Replay(scores: scores, selection: nil, selectedHexColor: nil, error: nil, tiedIndices: [])
        }

        let tiedIndices = eligible.filter { $0.score == minimum }.map(\.index)
        let selection = tiedIndices.first
        return Replay(
            scores: scores,
            selection: selection,
            selectedHexColor: selection.map { palette[$0].hex },
            error: minimum,
            tiedIndices: tiedIndices
        )
    }

    /// Maps corpus weight keys onto `ChannelWeights`; unknown light sources
    /// (e.g. `ultraviolet`) are ignored, matching the Elixir scorer's
    /// `filter_weights/1`.
    private func channelWeights(from map: [String: Double]) -> ChannelWeights {
        var weights = ChannelWeights()
        for (key, value) in map {
            switch key {
            case "white": weights.white = value
            case "red": weights.red = value
            case "green": weights.green = value
            case "blue": weights.blue = value
            case "lps": weights.lps = value
            default: break
            }
        }
        return weights
    }

    private func brightness(from channels: [String: Double]) -> [LightingCondition: Double] {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in channels {
            if let condition = LightingCondition(rawValue: key) {
                brightness[condition] = value
            }
        }
        return brightness
    }

    private func paletteColor(from entry: VectorEntry, index: Int) -> PaletteColor? {
        guard let rgb = RGBColor(hex: entry.hex_color) else { return nil }
        let responses = brightness(from: entry.channels).mapValues { IlluminationResponse(brightness: $0) }
        return PaletteColor(id: index, hex: entry.hex_color, rgb: rgb, responses: responses)
    }
}
