import Foundation
import XCTest
@testable import ColorComposerCore

// MARK: - Corpus wire model (viamin/color_matching `priv/parity/v1/corpus.json`)

/// One entry in a scenario's expected per-candidate score table: either a
/// finite score or the literal `"excluded"`.
private enum ParityScore: Equatable {
    case score(Double)
    case excluded
}

private struct ParityCorpus: Decodable {
    struct Vector: Decodable {
        let index: Int?
        let hexColor: String
        let channels: [String: Double]

        enum CodingKeys: String, CodingKey {
            case index
            case hexColor = "hex_color"
            case channels
        }
    }

    struct Expectation: Decodable {
        struct CandidateScore: Decodable {
            let index: Int
            let score: ParityScore
        }

        let scores: [CandidateScore]
        let selectedIndex: Int?
        let selectedHexColor: String?
        let error: Double?
        let tieBroke: Bool?
        let tiedIndices: [Int]

        enum CodingKeys: String, CodingKey {
            case scores
            case selectedIndex = "selected_index"
            case selectedHexColor = "selected_hex_color"
            case error
            case tieBroke = "tie_broke"
            case tiedIndices = "tied_indices"
        }
    }

    struct Scenario: Decodable {
        let id: String
        let description: String
        let weights: [String: Double]
        let target: Vector
        let palette: [Vector]
        let expected: Expectation
    }

    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
    let scenarios: [Scenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case scorer
        case selection
        case missingPolicy = "missing_policy"
        case lightSources = "light_sources"
        case scenarios
    }
}

extension ParityScore: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .score(value)
        } else if let literal = try? container.decode(String.self), literal == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: #"Expected a numeric score or the literal "excluded"."#
            ))
        }
    }
}

private extension ParityCorpus.Expectation {
    var excludedCandidateCount: Int {
        scores.filter { entry in
            if case .excluded = entry.score { return true } else { return false }
        }.count
    }
}

// MARK: - Parity replay

/// Replays the committed `color_matching` solver parity corpus through
/// `WeightedSquaredErrorScorer` and `CompositionSolver`, asserting exact
/// agreement with the recorded expectations — per-candidate scores, the
/// earliest-index-wins selection (including explicit tie cases), the winning
/// error, tie evidence, and missing-measurement exclusions.
///
/// The corpus is the shared source of truth published by the Elixir server
/// (see `docs/solver-parity-corpus.md`): it is vendored byte-identical at
/// `Fixtures/parity/v1/corpus.json` next to this file. Set `PARITY_CORPUS_PATH`
/// to replay a freshly downloaded corpus before committing it.
///
/// Scores are compared with exact `==`: every corpus magnitude is a dyadic
/// rational (channel values in eighths/sixteenths, weights in quarters), so
/// each partial sum is exactly representable and the summation order — Elixir
/// map order versus canonical `LightingCondition` order — cannot change the
/// result. Exact equality is the parity contract; do not loosen it.
final class SolverParityCorpusTests: XCTestCase {
    private let scorer = WeightedSquaredErrorScorer()

    // MARK: Corpus contract

    func testCorpusMetadataMatchesSupportedAlgorithmVersion() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1, """
            The corpus algorithm_version moved, so every expectation in it moved. \
            Refresh the vendored fixture and update this check in lockstep \
            (see docs/solver-parity-corpus.md).
            """)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
    }

    /// Guards the refresh path: a regenerated corpus that silently dropped its
    /// tie, exclusion, or no-selection coverage would keep these tests green
    /// while no longer policing the semantics they exist for.
    func testCorpusStillExercisesTiesExclusionsAndNoSelection() throws {
        let corpus = try loadCorpus()
        XCTAssertFalse(corpus.scenarios.isEmpty)

        XCTAssertEqual(Set(corpus.scenarios.map(\.id)).count, corpus.scenarios.count, "scenario ids must be unique")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true }, "at least one explicit tie case is required")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil }, "at least one no-selection case is required")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.excludedCandidateCount > 0 }, "at least one exclusion case is required")

        for scenario in corpus.scenarios {
            XCTAssertFalse(makeWeights(scenario.weights).activeConditions.isEmpty, """
                \(scenario.id): at least one canonical light source must carry a positive weight
                """)
            for (position, entry) in scenario.palette.enumerated() {
                XCTAssertEqual(entry.index, position, "\(scenario.id): palette entry index must match its position")
            }
            XCTAssertEqual(scenario.expected.scores.map(\.index), Array(scenario.palette.indices), "\(scenario.id): score table must cover the palette")
        }
    }

    // MARK: Scorer parity

    func testScorerReplaysEveryCandidateScoreExactly() throws {
        let corpus = try loadCorpus()
        for scenario in corpus.scenarios {
            let weights = makeWeights(scenario.weights)
            let target = makeTarget(scenario.target)
            let palette = try makePalette(scenario.palette)

            for entry in scenario.expected.scores {
                let result = scorer.score(candidate: palette[entry.index], target: target, weights: weights)
                switch (result, entry.score) {
                case (.excluded, .excluded):
                    break
                case (.score(let value), .score(let expected)):
                    XCTAssertEqual(value, expected, "\(scenario.id)[\(entry.index)]")
                default:
                    XCTFail("\(scenario.id)[\(entry.index)]: expected \(entry.score), got \(result)")
                }
            }
        }
    }

    /// Mirrors `ColorMatching.IlluminantMatching.best_match/4`: lowest score
    /// wins, the earliest index wins ties, and an all-excluded scenario yields
    /// no selection at all.
    func testSelectionMatchesEarliestIndexWinsIncludingTies() throws {
        let corpus = try loadCorpus()
        for scenario in corpus.scenarios {
            let weights = makeWeights(scenario.weights)
            let target = makeTarget(scenario.target)
            let palette = try makePalette(scenario.palette)
            let expected = scenario.expected

            var best: (index: Int, score: Double)?
            var tied: [Int] = []
            for (index, color) in palette.enumerated() {
                guard case .score(let value) = scorer.score(candidate: color, target: target, weights: weights) else { continue }
                if let current = best, value == current.score {
                    tied.append(index)
                } else if best == nil || value < best!.score {
                    best = (index, value)
                    tied = [index]
                }
            }

            if let selectedIndex = expected.selectedIndex {
                let winner = try XCTUnwrap(best, "\(scenario.id): expected a selection")
                let expectedError = try XCTUnwrap(expected.error, "\(scenario.id): expected a winning error")
                let expectedHexColor = try XCTUnwrap(expected.selectedHexColor, "\(scenario.id): expected a selected hex color")
                let expectedTieBroke = try XCTUnwrap(expected.tieBroke, "\(scenario.id): expected tie evidence")
                XCTAssertEqual(winner.index, selectedIndex, "\(scenario.id)")
                XCTAssertEqual(winner.score, expectedError, "\(scenario.id)")
                XCTAssertEqual(palette[winner.index].hex, expectedHexColor, "\(scenario.id)")
                XCTAssertEqual(tied, expected.tiedIndices, "\(scenario.id)")
                XCTAssertEqual(tied.count > 1, expectedTieBroke, "\(scenario.id)")
            } else {
                XCTAssertNil(best, "\(scenario.id): expected every candidate excluded")
                XCTAssertEqual(expected.tiedIndices, [], "\(scenario.id)")
                XCTAssertNil(expected.error, "\(scenario.id)")
                XCTAssertNil(expected.tieBroke, "\(scenario.id)")
                XCTAssertNil(expected.selectedHexColor, "\(scenario.id)")
            }
        }
    }

    // MARK: Solver parity (the fast path the app actually runs)

    /// Replays every scenario whose target carries all positive-weight
    /// channels through `CompositionSolver`'s optimized path with a 1×1 grid.
    /// Corpus scenarios whose *target* is missing an active channel cannot be
    /// expressed through the solver — source grids always supply a target
    /// value — so that exclusion policy is covered at the scorer level above.
    func testSolverFastPathReproducesCorpusSelection() throws {
        let corpus = try loadCorpus()
        for scenario in corpus.scenarios {
            let weights = makeWeights(scenario.weights)
            let active = weights.activeEntries
            let targetChannels = scenario.target.channels
            let solverReplayable = active.allSatisfy { targetChannels[$0.condition.rawValue] != nil }
            if !solverReplayable { continue }

            let palette = try makePalette(scenario.palette)
            var grids: [LightingCondition: BrightnessGrid] = [:]
            for (condition, _) in active {
                let value = targetChannels[condition.rawValue] ?? 0
                grids[condition] = BrightnessGrid(width: 1, height: 1, values: [value])
            }

            let result = try CompositionSolver(scorer: scorer).solve(
                palette: palette,
                sourceGrids: grids,
                weights: weights
            )
            let expected = scenario.expected

            if let selectedIndex = expected.selectedIndex {
                XCTAssertEqual(result.colorIndex(x: 0, y: 0), selectedIndex, "\(scenario.id)")
                let expectedError = try XCTUnwrap(expected.error, "\(scenario.id)")
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, "\(scenario.id)")
                XCTAssertEqual(result.unmatchedCellCount, 0, "\(scenario.id)")
            } else {
                XCTAssertNil(result.colorIndex(x: 0, y: 0), "\(scenario.id)")
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, "\(scenario.id)")
                XCTAssertEqual(result.unmatchedCellCount, 1, "\(scenario.id)")
            }
            XCTAssertEqual(result.excludedCandidateCount, expected.excludedCandidateCount, "\(scenario.id)")
        }
    }

    // MARK: Corpus loading and conversion

    private func loadCorpus() throws -> ParityCorpus {
        let url = corpusFileURL()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            XCTFail("""
                Could not read the parity corpus at \(url.path). \
                Refresh the fixture per docs/solver-parity-corpus.md (\(error)).
                """)
            throw error
        }
        return try JSONDecoder().decode(ParityCorpus.self, from: data)
    }

    /// The committed fixture next to this test file; `PARITY_CORPUS_PATH`
    /// replays an arbitrary corpus (for example a freshly downloaded one)
    /// without recommitting it.
    private func corpusFileURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["PARITY_CORPUS_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parity/v1/corpus.json")
    }

    /// Weight keys outside the canonical light sources (the corpus's
    /// `unknown-weight-ignored` scenario carries `ultraviolet`) are dropped,
    /// mirroring the Elixir `filter_weights/1` and the fixed condition set.
    private func makeWeights(_ raw: [String: Double]) -> ChannelWeights {
        func value(_ condition: LightingCondition) -> Double { raw[condition.rawValue] ?? 0 }
        return ChannelWeights(
            white: value(.white),
            red: value(.red),
            green: value(.green),
            blue: value(.blue),
            lps: value(.lps)
        )
    }

    private func makePalette(_ vectors: [ParityCorpus.Vector]) throws -> [PaletteColor] {
        try vectors.map(makeColor)
    }

    private func makeColor(_ vector: ParityCorpus.Vector) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: vector.hexColor), "corpus hex must parse: \(vector.hexColor)")
        return PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: rgb,
            responses: vector.channels.reduce(into: [:]) { responses, pair in
                guard let condition = LightingCondition(rawValue: pair.key) else { return }
                responses[condition] = IlluminationResponse(brightness: pair.value)
            }
        )
    }

    private func makeTarget(_ vector: ParityCorpus.Vector) -> TargetResponseVector {
        let brightness = vector.channels.reduce(into: [LightingCondition: Double]()) { target, pair in
            guard let condition = LightingCondition(rawValue: pair.key) else { return }
            target[condition] = pair.value
        }
        return TargetResponseVector(brightness)
    }
}
