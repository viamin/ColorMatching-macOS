import Foundation
import XCTest
@testable import ColorComposerCore

/// Solver parity against the committed golden-vector corpus from the
/// `color_matching` server (viamin/color_matching#111, merged as #112).
///
/// The corpus is byte-identical to `priv/parity/v1/corpus.json` in the server
/// repo and is replayed by BOTH test suites (Elixir + this one), so silent
/// divergence in tie-breaking, missing-measurement exclusion, or channel
/// weighting fails on at least one side. It pins:
///
/// - per-candidate scores (exact values, `1e-12` tolerance),
/// - earliest-index-wins selection — including exact ties — for
///   `WeightedSquaredErrorScorer` + the selection policy the solver uses,
/// - exclusion when any positive-weight channel is missing on the candidate
///   *or* the target, while zero-weight and unknown channels are ignored,
/// - an end-to-end `CompositionSolver` run for every scenario whose target
///   carries all positive-weight channels (the solver's fast path is what the
///   app actually uses).
///
/// Corpus location + refresh procedure: `docs/solver-parity-corpus.md`.
final class SolverParityCorpusTests: XCTestCase {
    // MARK: - Corpus wire model (test-local Codable mirror of the JSON schema)

    private struct Corpus: Codable {
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

    private struct Scenario: Codable {
        let id: String
        let description: String
        let weights: [String: Double]
        let target: Vector
        let palette: [Vector]
        let expected: Expected
    }

    private struct Vector: Codable {
        let index: Int?
        let hexColor: String?
        let channels: [String: Double]

        enum CodingKeys: String, CodingKey {
            case index
            case hexColor = "hex_color"
            case channels
        }
    }

    private struct Expected: Codable {
        let scores: [ExpectedScore]
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

    private struct ExpectedScore: Codable {
        let index: Int
        let score: ScoreValue
    }

    /// The corpus encodes excluded candidates as the string `"excluded"`
    /// instead of a number.
    private enum ScoreValue: Codable, Equatable {
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
                    debugDescription: "Expected a numeric score or the string \"excluded\"."
                )
            }
        }
    }

    // MARK: - Fixture loading

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Parity/v1/corpus.json")

    private static let corpus: Corpus = {
        guard let data = try? Data(contentsOf: fixtureURL) else {
            fatalError("Missing parity corpus fixture at \(fixtureURL.path). See docs/solver-parity-corpus.md.")
        }
        do {
            return try JSONDecoder().decode(Corpus.self, from: data)
        } catch {
            fatalError("Undecodable parity corpus fixture at \(fixtureURL.path): \(error)")
        }
    }()

    // MARK: - Corpus → domain mapping

    /// Maps corpus weights onto `ChannelWeights`, dropping unknown light
    /// sources the way the Elixir scorer's `filter_weights/1` does (exercised
    /// by the `unknown-weight-ignored` scenario, whose weights carry an
    /// `ultraviolet` key).
    private func channelWeights(_ raw: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: raw["white"] ?? 0,
            red: raw["red"] ?? 0,
            green: raw["green"] ?? 0,
            blue: raw["blue"] ?? 0,
            lps: raw["lps"] ?? 0
        )
    }

    private func paletteColor(from vector: Vector) throws -> PaletteColor {
        guard let hex = vector.hexColor else {
            throw XCTSkip("Corpus palette entry \(vector.index ?? -1) has no hex_color")
        }
        guard let rgb = RGBColor(hex: hex) else {
            throw XCTSkip("Corpus hex \(hex) is not parseable by RGBColor(hex:)")
        }
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, value) in vector.channels {
            guard let condition = LightingCondition(rawValue: key) else { continue }
            responses[condition] = IlluminationResponse(brightness: value)
        }
        return PaletteColor(id: vector.index ?? 0, hex: hex, rgb: rgb, responses: responses)
    }

    private func targetVector(from vector: Vector) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in vector.channels {
            if let condition = LightingCondition(rawValue: key) {
                brightness[condition] = value
            }
        }
        return TargetResponseVector(brightness)
    }

    // MARK: - Selection policy replay

    private struct Selection {
        let selectedIndex: Int?
        let winningScore: Double?
        let tiedIndices: [Int]
    }

    /// Replays the documented selection policy shared by the Elixir
    /// `IlluminantMatching.best_match/4` and `CompositionSolver`: rank by
    /// ascending score, skip excluded candidates, earliest index wins ties.
    private func earliestWinningSelection(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> Selection {
        var bestIndex: Int?
        var bestScore: Double?
        var rankableScores: [Int: Double] = [:]

        for (index, color) in palette.enumerated() {
            guard case .score(let value) = WeightedSquaredErrorScorer()
                .score(candidate: color, target: target, weights: weights)
            else { continue }
            rankableScores[index] = value
            if value < (bestScore ?? .infinity) {
                bestScore = value
                bestIndex = index
            }
        }

        guard let winner = bestIndex, let winningScore = bestScore else {
            return Selection(selectedIndex: nil, winningScore: nil, tiedIndices: [])
        }
        let tied = rankableScores
            .filter { abs($0.value - winningScore) < 1e-12 }
            .keys
            .sorted()
        return Selection(selectedIndex: winner, winningScore: winningScore, tiedIndices: tied)
    }

    /// `true` when the scenario target carries a measurement for every
    /// positive-weight channel, i.e. the target is representable as
    /// `BrightnessGrid` inputs for the end-to-end solver run. The corpus's
    /// `missing-target-excluded` scenario is deliberately not.
    private func hasCompleteTarget(_ scenario: Scenario, weights: ChannelWeights) -> Bool {
        let target = targetVector(from: scenario.target)
        return weights.activeEntries.allSatisfy { target.value(for: $0.condition) != nil }
    }

    // MARK: - Tests

    /// The corpus must still describe the semantics this app enforces. When
    /// the server bumps `algorithm_version` or renames its policies, the
    /// fixture and these expectations must be refreshed together
    /// (docs/solver-parity-corpus.md), not silently re-interpreted.
    func testCorpusMetadataMatchesEnforcedSemantics() throws {
        let corpus = Self.corpus
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(
            Set(corpus.lightSources),
            Set(LightingCondition.allCases.map(\.rawValue)),
            "Corpus light sources must match the client's canonical lighting conditions"
        )
        XCTAssertEqual(corpus.scenarios.count, 12, "Scenario count drift means the corpus was regenerated; update this suite")
    }

    /// The named tie and exclusion scenarios must stay in the corpus so the
    /// guarantees below keep concrete coverage.
    func testCorpusKeepsTieAndExclusionScenarios() throws {
        let ids = Set(Self.corpus.scenarios.map(\.id))
        for required in [
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
            "mixed-large-palette",
        ] {
            XCTAssertTrue(ids.contains(required), "Corpus is missing scenario \(required)")
        }
    }

    /// Every per-candidate expected score must match the Swift scorer's score
    /// exactly — numeric values within `1e-12`, exclusions as `.excluded`.
    func testPerCandidateScoresMatchCorpusExactly() throws {
        for scenario in Self.corpus.scenarios {
            let weights = channelWeights(scenario.weights)
            let target = targetVector(from: scenario.target)
            let palette = try scenario.palette.map(paletteColor(from:))
            let scorer = WeightedSquaredErrorScorer()

            XCTAssertEqual(
                scenario.expected.scores.count,
                palette.count,
                "\(scenario.id): expected.scores must cover the whole palette"
            )

            for expectedScore in scenario.expected.scores {
                guard expectedScore.index < palette.count else {
                    XCTFail("\(scenario.id): score index \(expectedScore.index) outside palette")
                    continue
                }
                let result = scorer.score(
                    candidate: palette[expectedScore.index],
                    target: target,
                    weights: weights
                )
                switch (result, expectedScore.score) {
                case (.score(let value), .score(let expected)):
                    XCTAssertEqual(
                        value, expected, accuracy: 1e-12,
                        "\(scenario.id): candidate \(expectedScore.index) score mismatch"
                    )
                case (.excluded, .excluded):
                    break
                default:
                    XCTFail(
                        "\(scenario.id): candidate \(expectedScore.index) produced \(result), "
                            + "corpus expects \(expectedScore.score)"
                    )
                }
            }
        }
    }

    /// Selections — including exact ties (earliest index wins) and the
    /// no-eligible-candidate cases — must match the corpus exactly.
    func testSelectionsMatchCorpusIncludingTies() throws {
        var tieScenarioCount = 0

        for scenario in Self.corpus.scenarios {
            let weights = channelWeights(scenario.weights)
            let target = targetVector(from: scenario.target)
            let palette = try scenario.palette.map(paletteColor(from:))
            let selection = earliestWinningSelection(palette: palette, target: target, weights: weights)
            let expected = scenario.expected

            XCTAssertEqual(
                selection.selectedIndex, expected.selectedIndex,
                "\(scenario.id): selected index mismatch"
            )

            if let winner = selection.selectedIndex {
                XCTAssertEqual(
                    palette[winner].hex, expected.selectedHexColor,
                    "\(scenario.id): selected hex mismatch"
                )
                if let expectedError = expected.error, let winningScore = selection.winningScore {
                    XCTAssertEqual(
                        winningScore, expectedError, accuracy: 1e-12,
                        "\(scenario.id): winning score mismatch"
                    )
                } else {
                    XCTFail("\(scenario.id): winner exists but error is not comparable")
                }
            } else {
                XCTAssertNil(expected.error, "\(scenario.id): no winner but expected an error")
            }

            XCTAssertEqual(
                selection.tiedIndices, expected.tiedIndices,
                "\(scenario.id): tied index set mismatch"
            )
            if scenario.expected.tieBroke == true { tieScenarioCount += 1 }
        }

        XCTAssertGreaterThanOrEqual(tieScenarioCount, 4, "Corpus must keep explicit tie coverage")
    }

    /// End-to-end: the solver (fast path the app uses) must reproduce the
    /// corpus selection, winning error, and exclusion count on a 1×1 grid for
    /// every scenario whose target carries all positive-weight channels. The
    /// `missing-target-excluded` scenario cannot be represented as brightness
    /// grids (a grid always supplies values), so it is pinned at scorer level
    /// above and surfaces in the app as a configuration error instead.
    func testSolverEndToEndMatchesCorpusForRepresentableTargets() throws {
        for scenario in Self.corpus.scenarios {
            let weights = channelWeights(scenario.weights)

            guard hasCompleteTarget(scenario, weights: weights) else {
                continue
            }

            let palette = try scenario.palette.map(paletteColor(from:))
            let target = targetVector(from: scenario.target)
            var sourceGrids: [LightingCondition: BrightnessGrid] = [:]
            for entry in weights.activeEntries {
                sourceGrids[entry.condition] = BrightnessGrid(
                    width: 1,
                    height: 1,
                    fill: target.value(for: entry.condition) ?? 0
                )
            }

            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: sourceGrids,
                weights: weights
            )

            XCTAssertEqual(
                result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex,
                "\(scenario.id): solver selection mismatch"
            )
            if let expectedError = scenario.expected.error {
                XCTAssertEqual(
                    result.error(x: 0, y: 0), expectedError, accuracy: 1e-12,
                    "\(scenario.id): solver winning error mismatch"
                )
            } else {
                XCTAssertEqual(
                    result.error(x: 0, y: 0), Double.infinity,
                    "\(scenario.id): no eligible candidate must record infinite error"
                )
            }
            let excludedCount = scenario.expected.scores
                .filter { $0.score == .excluded }
                .count
            XCTAssertEqual(
                result.excludedCandidateCount, excludedCount,
                "\(scenario.id): excluded candidate count mismatch"
            )
        }
    }

    /// The scorer-level replay of `missing-target-excluded` must produce no
    /// selection at all (every candidate excluded), never a zero-brightness
    /// interpretation of the missing channel.
    func testMissingTargetChannelExcludesEveryCandidate() throws {
        guard let scenario = Self.corpus.scenarios.first(where: { $0.id == "missing-target-excluded" }) else {
            return XCTFail("Corpus is missing the missing-target-excluded scenario")
        }
        let weights = channelWeights(scenario.weights)
        let target = targetVector(from: scenario.target)
        let palette = try scenario.palette.map(paletteColor(from:))

        let selection = earliestWinningSelection(palette: palette, target: target, weights: weights)
        XCTAssertNil(selection.selectedIndex)
        XCTAssertTrue(selection.tiedIndices.isEmpty)
        XCTAssertNil(scenario.expected.selectedIndex)
    }
}
