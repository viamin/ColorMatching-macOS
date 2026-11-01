import XCTest
@testable import ColorComposerCore

/// Replays the solver parity corpus committed from `viamin/color_matching`
/// (`priv/parity/v1/corpus.json`, see viamin/color_matching#111) through
/// `WeightedSquaredErrorScorer` and `CompositionSolver`, asserting exact
/// agreement with the server-recorded score tables, selections, errors, and
/// tie-break evidence.
///
/// The corpus is the contract that the Swift scorer deliberately mirrors the
/// Elixir `ColorMatching.WeightedSquaredError` solver: same channel weighting,
/// same missing-measurement exclusion (never treated as zero brightness), and
/// the same earliest-index-wins tie policy as
/// `ColorMatching.IlluminantMatching.best_match/4`. Any failure here means the
/// two implementations have diverged.
///
/// Refresh: `docs/solver-parity-corpus.md`.
final class SolverParityCorpusTests: XCTestCase {
    /// Corpus values are exact binary fractions (k/2^n), so scores round-trip
    /// JSON→Double losslessly; the epsilon only guards transitivity of
    /// near-equality, it must never absorb a real divergence.
    private static let scoreAccuracy = 1e-12

    // MARK: - Corpus metadata

    /// The corpus stamps name the exact algorithm it was generated from; a
    /// change to any stamp means every expectation has moved and this test
    /// suite (and the app) must be re-validated against a regenerated corpus.
    func testCorpusMetadataMatchesContract() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1, "A new corpus version requires re-validating parity")
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
    }

    /// Guards the corpus against a refresh that silently drops the evidence
    /// this suite exists to pin: deliberate ties (two- and three-way), a
    /// partial-exclusion scenario, an all-excluded scenario, a zero-weight
    /// channel, and an unknown light-source weight key.
    func testCorpusRetainsTieAndExclusionCoverage() throws {
        let corpus = try loadCorpus()
        let scenarios = corpus.scenarios
        let byID = { (id: String) in scenarios.first(where: { $0.id == id }) }

        let tieScenarios = scenarios.filter { $0.expected.tieBroke == true }
        XCTAssertGreaterThanOrEqual(tieScenarios.count, 3, "Corpus must retain deliberate tie scenarios")
        XCTAssertGreaterThanOrEqual(tieScenarios.filter { $0.expected.tiedIndices.count >= 3 }.count, 1,
                                    "Corpus must retain a multi-way (≥3) tie")

        XCTAssertNotNil(byID("missing-candidate-excluded"))
        XCTAssertNotNil(byID("unknown-weight-ignored"))
        XCTAssertNotNil(byID("zero-weight-channel-missing"))

        let allExcluded = scenarios.filter { $0.expected.selectedIndex == nil && !$0.palette.isEmpty }
        XCTAssertGreaterThanOrEqual(allExcluded.count, 2, "Corpus must retain all-excluded scenarios")
    }

    // MARK: - Scorer score table parity

    /// Per-candidate parity: every palette color's score (or exclusion)
    /// matches the server-recorded score table exactly — including
    /// missing-measurement exclusions and unknown weight keys being ignored.
    func testScorerScoreTableMatchesCorpusExactly() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let palette = try self.palette(for: scenario)
            let target = self.target(for: scenario)
            let weights = self.weights(for: scenario)

            XCTAssertEqual(
                Set(scenario.expected.scores.map(\.index)), Set(palette.map(\.id)),
                "Scenario \(scenario.id): score table must cover the whole palette"
            )

            for entry in scenario.expected.scores {
                let candidate = try XCTUnwrap(palette.first(where: { $0.id == entry.index }))
                let result = scorer.score(candidate: candidate, target: target, weights: weights)
                switch (result, entry.score) {
                case (.score(let value), .value(let expected)):
                    XCTAssertEqual(value, expected, accuracy: Self.scoreAccuracy,
                                   "Scenario \(scenario.id): candidate \(entry.index) score mismatch")
                case (.excluded, .excluded):
                    break
                default:
                    XCTFail("Scenario \(scenario.id): candidate \(entry.index) was \(result) "
                            + "but the corpus recorded \(entry.score)")
                }
            }
        }
    }

    // MARK: - Selection and tie parity

    /// Selection parity under the corpus's `earliest-index-wins` policy: the
    /// winner, its hex, its error, `tie_broke`, and the full `tied_indices`
    /// set must match exactly — including the no-rankable-candidate case.
    func testSelectionAndTieBreakingMatchCorpusExactly() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let palette = try self.palette(for: scenario)
            let target = self.target(for: scenario)
            let weights = self.weights(for: scenario)

            let ranked = palette.compactMap { candidate -> (index: Int, score: Double)? in
                guard case .score(let value) = scorer.score(candidate: candidate, target: target, weights: weights) else {
                    return nil
                }
                return (candidate.id, value)
            }

            guard let best = ranked.map(\.score).min() else {
                XCTAssertNil(scenario.expected.selectedIndex,
                             "Scenario \(scenario.id): corpus selected a winner but every candidate is excluded")
                XCTAssertNil(scenario.expected.error)
                XCTAssertNil(scenario.expected.tieBroke)
                XCTAssertEqual(scenario.expected.tiedIndices, [], "Scenario \(scenario.id)")
                continue
            }

            let tied = ranked.filter { $0.score == best }.map(\.index)
            let selected = try XCTUnwrap(tied.first, "Scenario \(scenario.id): tie set cannot be empty")
            let selectedColor = try XCTUnwrap(palette.first(where: { $0.id == selected }))

            XCTAssertEqual(selected, scenario.expected.selectedIndex, "Scenario \(scenario.id): selection mismatch")
            XCTAssertEqual(selectedColor.hex, scenario.expected.selectedHexColor, "Scenario \(scenario.id)")
            XCTAssertEqual(best, try XCTUnwrap(scenario.expected.error, "Scenario \(scenario.id): expected an error"),
                           accuracy: Self.scoreAccuracy)
            XCTAssertEqual(try XCTUnwrap(scenario.expected.tieBroke), tied.count > 1,
                           "Scenario \(scenario.id): tie_broke mismatch")
            XCTAssertEqual(tied, scenario.expected.tiedIndices, "Scenario \(scenario.id): tied_indices mismatch")
        }
    }

    // MARK: - Solver replay

    /// End-to-end parity through `CompositionSolver`, which owns the
    /// earliest-wins tie policy the corpus records. Each scenario's target
    /// vector becomes a 1×1 source grid per active channel; the solver's
    /// chosen cell, error, and exclusion counts must match the corpus.
    func testSolverReplayMatchesCorpusSelection() throws {
        let corpus = try loadCorpus()
        let solver = CompositionSolver(scorer: WeightedSquaredErrorScorer())

        for scenario in corpus.scenarios {
            let palette = try self.palette(for: scenario)
            let weights = self.weights(for: scenario)
            let targetChannels = scenario.target.channels

            // The app maps an absent source image to a missing grid, which the
            // solver rejects outright — there is no "target missing a channel"
            // cell to score. Only the server-side scorer can express that
            // case, so here we assert the solver's guard instead.
            let active = weights.activeConditions
            if let missing = active.first(where: { targetChannels[$0.rawValue] == nil }) {
                XCTAssertThrowsError(
                    try solver.solve(palette: palette, sourceGrids: sourceGrids(for: scenario, weights: weights),
                                     weights: weights),
                    "Scenario \(scenario.id) should be rejected for a missing grid"
                ) { error in
                    XCTAssertEqual(error as? CompositionSolverError, .missingSourceGrid(missing),
                                   "Scenario \(scenario.id)")
                }
                continue
            }

            let result = try solver.solve(
                palette: palette,
                sourceGrids: sourceGrids(for: scenario, weights: weights),
                weights: weights
            )

            if let selected = scenario.expected.selectedIndex {
                XCTAssertEqual(result.colorIndex(x: 0, y: 0), selected,
                               "Scenario \(scenario.id): solver selection mismatch")
                XCTAssertEqual(result.error(x: 0, y: 0), try XCTUnwrap(scenario.expected.error),
                               accuracy: Self.scoreAccuracy, "Scenario \(scenario.id): solver error mismatch")
                XCTAssertEqual(result.unmatchedCellCount, 0, "Scenario \(scenario.id)")
            } else {
                XCTAssertNil(result.colorIndex(x: 0, y: 0), "Scenario \(scenario.id): expected no selection")
                XCTAssertEqual(result.unmatchedCellCount, 1, "Scenario \(scenario.id)")
                XCTAssertEqual(result.excludedCandidateCount, palette.count, "Scenario \(scenario.id)")
            }
        }
    }

    // MARK: - Corpus loading

    /// Loads the corpus committed beside these tests. Located via `#filePath`
    /// so no bundle-resource declaration is required (SwiftPM test targets
    /// have no `Bundle.module` resources by default).
    private func loadCorpus(file: StaticString = #filePath, line: UInt = #line) throws -> ParityCorpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ParityCorpus/v1/corpus.json")
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(ParityCorpus.self, from: data)
        } catch {
            XCTFail("Could not load the parity corpus at \(url.path): \(error)", file: file, line: line)
            throw error
        }
    }

    // MARK: - Scenario → domain conversion

    private func weights(for scenario: ParityCorpus.Scenario) -> ChannelWeights {
        func value(_ condition: LightingCondition) -> Double {
            scenario.weights[condition.rawValue] ?? 0
        }
        return ChannelWeights(
            white: value(.white), red: value(.red), green: value(.green),
            blue: value(.blue), lps: value(.lps)
        )
    }

    private func target(for scenario: ParityCorpus.Scenario) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in scenario.target.channels {
            if let condition = LightingCondition(rawValue: key) {
                brightness[condition] = value
            }
        }
        return TargetResponseVector(brightness)
    }

    /// Palette in corpus index order, with the candidate's `index` as its id
    /// so score-table entries and tie sets address the same colors.
    private func palette(for scenario: ParityCorpus.Scenario) throws -> [PaletteColor] {
        try scenario.palette.map { candidate in
            let rgb = try XCTUnwrap(RGBColor(hex: candidate.hexColor),
                                    "Scenario \(scenario.id): unparseable hex \(candidate.hexColor)")
            var responses: [LightingCondition: IlluminationResponse] = [:]
            for (key, brightness) in candidate.channels {
                if let condition = LightingCondition(rawValue: key) {
                    responses[condition] = IlluminationResponse(brightness: brightness)
                }
            }
            return PaletteColor(id: candidate.index, hex: candidate.hexColor, rgb: rgb, responses: responses)
        }
    }

    /// One 1×1 grid per active channel carrying the scenario's target value,
    /// mirroring how a source image's sampled cell reaches the scorer.
    private func sourceGrids(for scenario: ParityCorpus.Scenario, weights: ChannelWeights)
        -> [LightingCondition: BrightnessGrid] {
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for (key, value) in scenario.target.channels {
            if let condition = LightingCondition(rawValue: key) {
                grids[condition] = BrightnessGrid(width: 1, height: 1, values: [value])
            }
        }
        return grids
    }
}

// MARK: - Corpus wire types (test-local)

/// Wire shape of `priv/parity/v1/corpus.json` from viamin/color_matching.
/// Test-local so the corpus format stays an affair of the parity suite.
private struct ParityCorpus: Decodable {
    struct Candidate: Decodable {
        let index: Int
        let hexColor: String
        let channels: [String: Double]
    }

    struct ScoreEntry: Decodable {
        let index: Int
        let score: ParityScore
    }

    struct Expected: Decodable {
        let selectedIndex: Int?
        let selectedHexColor: String?
        let error: Double?
        let tieBroke: Bool?
        let tiedIndices: [Int]
        let scores: [ScoreEntry]
    }

    struct Scenario: Decodable {
        let id: String
        let description: String
        let palette: [Candidate]
        let target: Candidate
        let weights: [String: Double]
        let expected: Expected
    }

    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scorer: String
    let selection: String
    let scenarios: [Scenario]
}

/// A recorded score is either a finite number or the literal `"excluded"`
/// marker for missing-measurement exclusions.
private enum ParityScore: Decodable, CustomStringConvertible {
    case value(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self), string == "excluded" {
            self = .excluded
        } else {
            self = .value(try container.decode(Double.self))
        }
    }

    var description: String {
        switch self {
        case .value(let value): return ".score(\(value))"
        case .excluded: return "excluded"
        }
    }
}
