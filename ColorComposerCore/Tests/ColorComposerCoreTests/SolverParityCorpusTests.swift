import XCTest
@testable import ColorComposerCore

/// Solver parity against the golden-vector corpus produced by the
/// `color_matching` backend (viamin/color_matching#111, committed by its
/// PR #112 as `priv/parity/v1/corpus.json`).
///
/// The corpus is the shared source of truth both test suites replay: every
/// scenario carries a palette of candidate response vectors, a target vector,
/// per-channel weights, and the *expected* `WeightedSquaredError` outcome
/// (per-candidate scores, selection, tie evidence) computed by the Elixir
/// solver. `WeightedSquaredErrorScorer` must reproduce those outcomes
/// bit-for-bit so client and server always agree on selection.
///
/// The fixture lives at `Tests/Fixtures/parity/v1/corpus.json` (outside the
/// SwiftPM target directory so no resource declaration is required) and is
/// loaded relative to this file. See `docs/parity-corpus.md` for where the
/// corpus comes from and how to refresh it.
final class SolverParityCorpusTests: XCTestCase {
    private static let expectedScenarioIDs = [
        "distinct-errors",
        "tie-symmetric-around-target",
        "tie-duplicate-vectors",
        "tie-three-way-on-lps",
        "missing-candidate-excluded",
        "missing-target-excluded",
        "zero-weight-channel-missing",
        "all-excluded",
        "single-channel-lps",
        "exact-match-zero-error",
        "unknown-weight-ignored",
        "mixed-large-palette"
    ]

    // MARK: - Corpus fixture decoding

    /// A corpus score: a JSON number, or the string `"excluded"`.
    private enum CorpusScore: Decodable, Equatable {
        case score(Double)
        case excluded

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let raw = try? container.decode(String.self), raw == "excluded" {
                self = .excluded
            } else {
                self = .score(try container.decode(Double.self))
            }
        }

        var isExcluded: Bool { self == .excluded }
    }

    private struct ExpectedOutcome: Decodable {
        struct ScoredCandidate: Decodable {
            let index: Int
            let score: CorpusScore
        }

        let scores: [ScoredCandidate]
        let selectedIndex: Int?
        let selectedHexColor: String?
        let error: Double?
        let tieBroke: Bool?
        let tiedIndices: [Int]
    }

    private struct Scenario: Decodable {
        struct Entry: Decodable {
            let index: Int?
            let hexColor: String
            let channels: [String: Double]
        }

        let id: String
        let description: String
        let weights: [String: Double]
        let target: Entry
        let palette: [Entry]
        let expected: ExpectedOutcome
    }

    private struct ParityCorpus: Decodable {
        let algorithmVersion: Int
        let scorer: String
        let selection: String
        let missingPolicy: String
        let lightSources: [String]
        let scenarios: [Scenario]
    }

    private static func loadCorpus(file: StaticString = #filePath) throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ColorComposerCoreTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures/parity/v1/corpus.json")
        guard let data = try? Data(contentsOf: fixtureURL) else {
            XCTFail("Parity corpus fixture is missing at \(fixtureURL.path) — see docs/parity-corpus.md for how to fetch it.")
            throw CocoaError(.fileNoSuchFile)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: data)
    }

    // MARK: - Corpus → domain mapping

    private func domainColor(from entry: Scenario.Entry, id: Int) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: entry.hexColor), "corpus hex \(entry.hexColor) must parse")
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, value) in entry.channels {
            if let condition = LightingCondition(rawValue: key) {
                responses[condition] = IlluminationResponse(brightness: value)
            }
        }
        return PaletteColor(id: id, hex: entry.hexColor, rgb: rgb, responses: responses)
    }

    private func targetVector(from entry: Scenario.Entry) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in entry.channels {
            if let condition = LightingCondition(rawValue: key) {
                brightness[condition] = value
            }
        }
        return TargetResponseVector(brightness)
    }

    /// Unknown weight keys (e.g. `ultraviolet`) are dropped: the client's
    /// channel set is exactly `LightingCondition.all`.
    private func channelWeights(from raw: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: raw["white"] ?? 0,
            red: raw["red"] ?? 0,
            green: raw["green"] ?? 0,
            blue: raw["blue"] ?? 0,
            lps: raw["lps"] ?? 0
        )
    }

    private func palette(for scenario: Scenario) throws -> [PaletteColor] {
        try scenario.palette.enumerated().map { index, entry in
            try domainColor(from: entry, id: index)
        }
    }

    // MARK: - Corpus metadata

    /// The corpus describes the *coupled* contract: which solver, which
    /// selection policy, which missing-measurement policy, and which light
    /// sources. A change in any of these means the parity semantics moved and
    /// this test (and its fixture) must be revisited deliberately.
    func testCorpusMetadataMatchesClientContract() throws {
        let corpus = try Self.loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1, "scorer semantics version moved upstream")
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
        XCTAssertEqual(corpus.scenarios.map(\.id), Self.expectedScenarioIDs)
    }

    /// The corpus must keep covering the behaviors most likely to drift:
    /// ties (including a three-way tie), exclusion of a missing candidate,
    /// exclusion via a missing target channel, and a fully-excluded palette.
    func testCorpusKeepsCoveringTieAndExclusionCases() throws {
        let corpus = try Self.loadCorpus()
        let outcomes = corpus.scenarios.map(\.expected)

        XCTAssertTrue(outcomes.contains { $0.tieBroke == true }, "no tie scenario in corpus")
        XCTAssertTrue(
            outcomes.contains { $0.tiedIndices.count >= 3 },
            "no three-way (or larger) tie scenario in corpus"
        )
        XCTAssertTrue(
            outcomes.contains { $0.selectedIndex == nil },
            "no no-selection scenario in corpus"
        )
        XCTAssertTrue(
            outcomes.contains { $0.scores.contains { $0.score.isExcluded } },
            "no excluded-candidate scenario in corpus"
        )
    }

    // MARK: - Scorer parity (all scenarios, exact)

    /// Every scenario must reproduce the Elixir solver exactly: per-candidate
    /// scores (or `excluded`), the earliest-index-wins selection, the selected
    /// color, the winning error, and the full tie evidence.
    ///
    /// Scores are compared with **exact** `Double` equality — no accuracy
    /// tolerance. Corpus values are dyadic rationals (channel brightness in
    /// 1/16ths, weights in 1/4ths), so every intermediate product and partial
    /// sum is exactly representable and summation order cannot perturb the
    /// result. A tolerance would hide real drift, not model float noise.
    func testWeightedSquaredErrorScorerMatchesCorpusExactlyIncludingTies() throws {
        let corpus = try Self.loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let weights = channelWeights(from: scenario.weights)
            let target = targetVector(from: scenario.target)
            let candidates = try palette(for: scenario)
            let scored = candidates.map { scorer.score(candidate: $0, target: target, weights: weights) }

            assertScoreParity(scored: scored, expected: scenario.expected, scenarioID: scenario.id)
            try assertSelectionParity(
                scored: scored,
                palette: scenario.palette,
                expected: scenario.expected,
                scenarioID: scenario.id
            )
        }
    }

    private func assertScoreParity(
        scored: [ScorerResult],
        expected: Scenario.ExpectedOutcome,
        scenarioID: String
    ) {
        XCTAssertEqual(scored.count, expected.scores.count, "\(scenarioID): candidate count")

        for candidate in expected.scores {
            let got = scored[candidate.index]
            switch (candidate.score, got) {
            case (.excluded, .excluded):
                break
            case (.score(let want), .score(let gotValue)):
                XCTAssertEqual(
                    gotValue,
                    want,
                    "\(scenarioID): candidate \(candidate.index) score"
                )
            default:
                XCTFail("\(scenarioID): candidate \(candidate.index) expected \(candidate.score), got \(got)")
            }
        }
    }

    private func assertSelectionParity(
        scored: [ScorerResult],
        palette: [Scenario.Entry],
        expected: Scenario.ExpectedOutcome,
        scenarioID: String
    ) throws {
        let selection = earliestWinningIndex(of: scored)

        XCTAssertEqual(selection?.index, expected.selectedIndex, "\(scenarioID): selected index")

        guard let selection else {
            XCTAssertNil(expected.selectedHexColor, "\(scenarioID): hex with no selection")
            XCTAssertNil(expected.error, "\(scenarioID): error with no selection")
            XCTAssertNil(expected.tieBroke, "\(scenarioID): tie flag with no selection")
            XCTAssertTrue(expected.tiedIndices.isEmpty, "\(scenarioID): ties with no selection")
            return
        }

        let expectedHex = try XCTUnwrap(expected.selectedHexColor, "\(scenarioID): hex missing with a selection")
        let expectedError = try XCTUnwrap(expected.error, "\(scenarioID): error missing with a selection")
        let expectedTieBroke = try XCTUnwrap(expected.tieBroke, "\(scenarioID): tie flag missing with a selection")

        XCTAssertEqual(
            palette[selection.index].hexColor,
            expectedHex,
            "\(scenarioID): selected hex color"
        )
        XCTAssertEqual(selection.score, expectedError, "\(scenarioID): winning error")

        let tied = scored.indices.filter { index in
            if case .score(let value) = scored[index] { return value == selection.score }
            return false
        }
        XCTAssertEqual(tied, expected.tiedIndices, "\(scenarioID): tied indices")
        XCTAssertEqual(tied.count > 1, expectedTieBroke, "\(scenarioID): tie_broke")
    }

    /// The corpus selection policy (`earliest-index-wins`): lowest score wins,
    /// and an equal score never displaces an earlier index.
    private func earliestWinningIndex(of scored: [ScorerResult]) -> (index: Int, score: Double)? {
        var winner: (index: Int, score: Double)?
        for (index, result) in scored.enumerated() {
            guard case .score(let value) = result else { continue }
            if winner == nil || value < winner!.score {
                winner = (index, value)
            }
        }
        return winner
    }

    // MARK: - Solver parity (production fast path)

    /// Replays every expressible scenario through the real `CompositionSolver`
    /// (1×1 grids, default scorer → the contiguous-array fast path used in
    /// production) and checks the solver agrees with the corpus on selection,
    /// error, and exclusion diagnostics.
    ///
    /// The one inexpressible scenario is `missing-target-excluded`: source
    /// grids always carry a value for every active condition, so a target
    /// *missing* a positive-weight channel cannot be built through `solve`;
    /// its parity is covered at the scorer level above.
    func testSolverFastPathMatchesCorpusSelection() throws {
        let corpus = try Self.loadCorpus()
        let solver = CompositionSolver(scorer: WeightedSquaredErrorScorer())

        for scenario in corpus.scenarios {
            let weights = channelWeights(from: scenario.weights)
            let active = weights.activeEntries
            let targetChannelValues = targetVector(from: scenario.target).brightness

            let targetIsMissingActiveChannel = active.contains { targetChannelValues[$0.condition] == nil }
            if targetIsMissingActiveChannel {
                XCTAssertNil(scenario.expected.selectedIndex, "\(scenario.id): expected no selection")
                continue
            }

            var grids: [LightingCondition: BrightnessGrid] = [:]
            for (condition, _) in active {
                grids[condition] = BrightnessGrid(
                    width: 1,
                    height: 1,
                    fill: targetChannelValues[condition]!
                )
            }

            let result = try solver.solve(
                palette: try palette(for: scenario),
                sourceGrids: grids,
                weights: weights
            )

            assertSolverParity(result: result, expected: scenario.expected, scenarioID: scenario.id)
        }
    }

    private func assertSolverParity(
        result: CompositionResult,
        expected: Scenario.ExpectedOutcome,
        scenarioID: String
    ) {
        XCTAssertEqual(result.colorIndices.first.flatMap { $0 }, expected.selectedIndex, "\(scenarioID): solver selection")
        XCTAssertEqual(
            result.excludedCandidateCount,
            expected.scores.filter { $0.score.isExcluded }.count,
            "\(scenarioID): excluded-candidate diagnostics"
        )

        guard let winningError = expected.error else {
            XCTAssertEqual(result.errors.first, .infinity, "\(scenarioID): unmatched-cell error")
            XCTAssertEqual(result.unmatchedCellCount, 1, "\(scenarioID): unmatched cells")
            return
        }
        XCTAssertEqual(result.errors.first, winningError, "\(scenarioID): winning error")
    }
}
