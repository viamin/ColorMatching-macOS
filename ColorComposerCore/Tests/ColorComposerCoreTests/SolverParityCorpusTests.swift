import XCTest
@testable import ColorComposerCore

/// Replays the `color_matching` solver parity corpus through this package's
/// solver and asserts exact agreement with the Elixir reference
/// (`ColorMatching.WeightedSquaredError`, issue #39).
///
/// The corpus is generated upstream by `mix parity.generate` and committed at
/// `priv/parity/v1/corpus.json` (viamin/color_matching#111). A byte-identical
/// copy lives at `Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json`;
/// see `docs/parity-corpus.md` for the refresh procedure.
///
/// Corpus pins (all asserted in `testCorpusMetadataMatchesSolverContract`):
/// - scorer: `ColorMatching.WeightedSquaredError`
/// - selection: earliest-index-wins tie-breaking
/// - missing policy: excluded when any positive-weight channel is missing
/// - `algorithm_version: 1`
///
/// Scenario `missing-target-excluded` cannot be expressed through
/// `CompositionSolver.solve` (the app guarantees a source grid for every
/// active channel, so a target can never be missing one); its exclusion
/// semantics are covered by the scorer-level tests instead.
final class SolverParityCorpusTests: XCTestCase {
    // MARK: - Corpus wire format

    private struct Corpus: Decodable {
        let algorithmVersion: Int
        let lightSources: [String]
        let missingPolicy: String
        let scorer: String
        let selection: String
        let scenarios: [Scenario]

        enum CodingKeys: String, CodingKey {
            case algorithmVersion = "algorithm_version"
            case lightSources = "light_sources"
            case missingPolicy = "missing_policy"
            case scorer
            case selection
            case scenarios
        }
    }

    private struct Scenario: Decodable {
        let id: String
        let description: String
        let palette: [PaletteEntry]
        let target: TargetVector
        let weights: [String: Double]
        let expected: ExpectedOutcome
    }

    private struct PaletteEntry: Decodable {
        let index: Int
        let hexColor: String
        /// Absent key = missing measurement (never "measured as zero").
        let channels: [String: Double]

        enum CodingKeys: String, CodingKey {
            case index
            case hexColor = "hex_color"
            case channels
        }
    }

    private struct TargetVector: Decodable {
        let channels: [String: Double]
    }

    private struct ExpectedOutcome: Decodable {
        let selectedIndex: Int?
        let selectedHexColor: String?
        let error: Double?
        let tieBroke: Bool?
        let tiedIndices: [Int]
        let scores: [ExpectedScoreEntry]

        enum CodingKeys: String, CodingKey {
            case selectedIndex = "selected_index"
            case selectedHexColor = "selected_hex_color"
            case error
            case tieBroke = "tie_broke"
            case tiedIndices = "tied_indices"
            case scores
        }
    }

    private struct ExpectedScoreEntry: Decodable {
        let index: Int
        let score: ExpectedScore
    }

    /// A corpus score is a finite weighted error or the `"excluded"` sentinel.
    private enum ExpectedScore: Decodable {
        case excluded
        case value(Double)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                self = .value(value)
            } else if let status = try? container.decode(String.self), status == "excluded" {
                self = .excluded
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: #"corpus score must be a number or "excluded""#
                )
            }
        }
    }

    // MARK: - Fixture access

    private static let corpusURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/parity/v1/corpus.json")

    private static func loadCorpus() throws -> Corpus {
        try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: corpusURL))
    }

    // MARK: - Corpus → domain conversion

    private static func domainPalette(for scenario: Scenario) throws -> [PaletteColor] {
        XCTAssertEqual(
            scenario.palette.map(\.index),
            Array(scenario.palette.indices),
            "scenario \(scenario.id): palette indices must be dense and ordered"
        )
        return try scenario.palette.map { entry in
            var responses: [LightingCondition: IlluminationResponse] = [:]
            for (key, value) in entry.channels {
                let condition = try XCTUnwrap(LightingCondition(rawValue: key))
                responses[condition] = IlluminationResponse(brightness: value)
            }
            let rgb = try XCTUnwrap(RGBColor(hex: entry.hexColor))
            return PaletteColor(id: entry.index, hex: entry.hexColor, rgb: rgb, responses: responses)
        }
    }

    private static func targetVector(for scenario: Scenario) throws -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in scenario.target.channels {
            brightness[try XCTUnwrap(LightingCondition(rawValue: key))] = value
        }
        return TargetResponseVector(brightness)
    }

    /// Unknown light-source keys (e.g. `ultraviolet`) are dropped — the app
    /// models the five canonical conditions only.
    private static func channelWeights(for scenario: Scenario) -> ChannelWeights {
        var weights = ChannelWeights()
        for (key, value) in scenario.weights {
            guard let condition = LightingCondition(rawValue: key) else { continue }
            switch condition {
            case .white: weights.white = value
            case .red: weights.red = value
            case .green: weights.green = value
            case .blue: weights.blue = value
            case .lps: weights.lps = value
            }
        }
        return weights
    }

    /// Raw target channel values keyed by light-source string (solver-path use).
    private static func rawTargetChannels(for scenario: Scenario) -> [String: Double] {
        scenario.target.channels
    }

    // MARK: - Selection (mirrors the documented earliest-wins policy)

    /// Scores every palette entry; excluded candidates are omitted.
    private func eligibleScores(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> [(index: Int, score: Double)] {
        let scorer = WeightedSquaredErrorScorer()
        var scored: [(index: Int, score: Double)] = []
        for (index, color) in palette.enumerated() {
            if case .score(let value) = scorer.score(candidate: color, target: target, weights: weights) {
                scored.append((index, value))
            }
        }
        return scored
    }

    /// Lowest score wins; the earliest index wins an exact tie.
    private func selectBest(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> (index: Int?, score: Double?) {
        var best: (index: Int, score: Double)?
        for entry in eligibleScores(palette: palette, target: target, weights: weights) {
            if best == nil || entry.score < best!.score {
                best = entry
            }
        }
        return (best?.index, best?.score)
    }

    // MARK: - Tests

    /// Guards against replaying a corpus generated under different policies:
    /// a metadata mismatch means upstream changed semantics, not that this
    /// solver drifted.
    func testCorpusMetadataMatchesSolverContract() throws {
        let corpus = try Self.loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1, "corpus algorithm_version changed — see docs/parity-corpus.md")
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(Set(corpus.lightSources), Set(LightingCondition.all.map(\.rawValue)))
        XCTAssertEqual(corpus.scenarios.count, 12)
        XCTAssertEqual(Set(corpus.scenarios.map(\.id)).count, corpus.scenarios.count, "scenario ids must be unique")
    }

    /// Every scenario's selected index, hex color, and minimum error must
    /// match the Elixir solver exactly — including the tie scenarios and the
    /// no-selection (all-excluded / missing-target) cases.
    func testSelectionsMatchExpectedOutputsExactly() throws {
        let corpus = try Self.loadCorpus()

        for scenario in corpus.scenarios {
            let palette = try Self.domainPalette(for: scenario)
            let target = try Self.targetVector(for: scenario)
            let weights = Self.channelWeights(for: scenario)
            let best = selectBest(palette: palette, target: target, weights: weights)

            XCTAssertEqual(best.index, scenario.expected.selectedIndex, "scenario \(scenario.id): selection mismatch")

            guard let index = best.index else {
                XCTAssertNil(scenario.expected.selectedHexColor, "scenario \(scenario.id): expected a selection")
                XCTAssertNil(scenario.expected.error, "scenario \(scenario.id): expected an error value")
                continue
            }
            XCTAssertEqual(
                palette[index].hex,
                scenario.expected.selectedHexColor,
                "scenario \(scenario.id): selected color hex mismatch"
            )
            let expectedError = try XCTUnwrap(scenario.expected.error, "scenario \(scenario.id): expected an error")
            XCTAssertEqual(best.score ?? .nan, expectedError, accuracy: 1e-12, "scenario \(scenario.id): error mismatch")
        }
    }

    /// Tie evidence must agree: which candidates tied at the best score, and
    /// whether the winner was decided by earliest-index tie-breaking.
    func testTieBreakingMatchesExpectedTieEvidence() throws {
        let corpus = try Self.loadCorpus()

        for scenario in corpus.scenarios {
            guard scenario.expected.selectedIndex != nil else { continue }
            let palette = try Self.domainPalette(for: scenario)
            let target = try Self.targetVector(for: scenario)
            let weights = Self.channelWeights(for: scenario)
            let scored = eligibleScores(palette: palette, target: target, weights: weights)

            let bestScore = try XCTUnwrap(scored.map(\.score).min(), "scenario \(scenario.id): expected an eligible candidate")
            let tied = scored.filter { abs($0.score - bestScore) <= 1e-12 }.map(\.index)

            XCTAssertEqual(tied, scenario.expected.tiedIndices, "scenario \(scenario.id): tied indices mismatch")
            XCTAssertEqual(
                tied.count > 1,
                scenario.expected.tieBroke ?? false,
                "scenario \(scenario.id): tie_broke mismatch"
            )
        }
    }

    /// Per-candidate scores (including `"excluded"` entries) must match for
    /// every palette member — pins exclusion and weight handling, not just
    /// the winner.
    func testPerCandidateScoresMatchIncludingExclusions() throws {
        let corpus = try Self.loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let palette = try Self.domainPalette(for: scenario)
            let target = try Self.targetVector(for: scenario)
            let weights = Self.channelWeights(for: scenario)

            XCTAssertEqual(
                scenario.expected.scores.count,
                scenario.palette.count,
                "scenario \(scenario.id): scores must cover the whole palette"
            )
            for entry in scenario.expected.scores {
                let result = scorer.score(candidate: palette[entry.index], target: target, weights: weights)
                switch entry.score {
                case .excluded:
                    XCTAssertEqual(result, .excluded, "scenario \(scenario.id): candidate \(entry.index) must be excluded")
                case .value(let expected):
                    guard case .score(let actual) = result else {
                        XCTFail("scenario \(scenario.id): candidate \(entry.index) unexpectedly excluded")
                        continue
                    }
                    XCTAssertEqual(actual, expected, accuracy: 1e-12, "scenario \(scenario.id): candidate \(entry.index) score mismatch")
                }
            }
        }
    }

    /// The production selection path (`CompositionSolver` fast path) must
    /// reproduce the corpus selections when each scenario is expressed as a
    /// 1×1 composition: same selected index, same error (or an unmatched cell
    /// with infinite error when every candidate is excluded), and the same
    /// excluded-candidate count.
    func testSolverFastPathSelectionMatchesCorpus() throws {
        let corpus = try Self.loadCorpus()

        for scenario in corpus.scenarios {
            let weights = Self.channelWeights(for: scenario)
            let rawTarget = Self.rawTargetChannels(for: scenario)

            // A target missing an active channel is inexpressible as source
            // grids; see the class docs. Its policy is covered scorer-side.
            let active = weights.activeConditions
            guard active.allSatisfy({ rawTarget[$0.rawValue] != nil }) else { continue }

            var grids: [LightingCondition: BrightnessGrid] = [:]
            for condition in active {
                grids[condition] = BrightnessGrid(width: 1, height: 1, fill: rawTarget[condition.rawValue]!)
            }

            let palette = try Self.domainPalette(for: scenario)
            let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)

            XCTAssertEqual(
                result.colorIndex(x: 0, y: 0),
                scenario.expected.selectedIndex,
                "scenario \(scenario.id): solver selection mismatch"
            )
            if let expectedError = scenario.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, "scenario \(scenario.id): solver error mismatch")
            } else {
                XCTAssertEqual(result.error(x: 0, y: 0), .infinity, "scenario \(scenario.id): expected an unmatched cell")
            }

            let expectedExcluded = scenario.expected.scores.filter {
                if case .excluded = $0.score { return true }
                return false
            }.count
            XCTAssertEqual(
                result.excludedCandidateCount,
                expectedExcluded,
                "scenario \(scenario.id): excluded-candidate count mismatch"
            )
        }
    }

    /// The corpus carries an unknown light source (`ultraviolet`) in its
    /// weights map: it must be ignored, not treated as a required channel.
    func testUnknownLightSourceWeightsAreIgnored() throws {
        let corpus = try Self.loadCorpus()
        let scenario = try XCTUnwrap(corpus.scenarios.first { $0.id == "unknown-weight-ignored" })

        XCTAssertTrue(scenario.weights.keys.contains("ultraviolet"), "corpus scenario changed upstream")
        let weights = Self.channelWeights(for: scenario)
        XCTAssertEqual(Set(weights.activeConditions.map(\.rawValue)), Set(["white", "red", "green", "blue", "lps"]))

        let palette = try Self.domainPalette(for: scenario)
        let best = selectBest(palette: palette, target: try Self.targetVector(for: scenario), weights: weights)
        XCTAssertEqual(best.index, scenario.expected.selectedIndex)
        XCTAssertEqual(best.score ?? .nan, try XCTUnwrap(scenario.expected.error), accuracy: 1e-12)
    }
}
