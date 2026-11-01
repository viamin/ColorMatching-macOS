import Foundation
import XCTest
@testable import ColorComposerCore

/// Solver parity against the corpus committed by the Elixir `color_matching`
/// service (viamin/color_matching#111, `algorithm_version` 1).
///
/// The corpus is a byte-identical copy of `priv/parity/v1/corpus.json` from
/// the color_matching repository, committed at
/// `Fixtures/parity_corpus.json` next to this test. Every scenario records
/// the full per-candidate score table the Elixir
/// `ColorMatching.WeightedSquaredError` solver produced, the index it
/// selected under its `earliest-index-wins` policy, and which candidates
/// tied — so both the scorer and the solver's fast path are pinned to the
/// server's exact behavior, ties included. See `docs/parity-corpus.md` for
/// the refresh procedure.
final class SolverParityCorpusTests: XCTestCase {
    /// Scenario ids the corpus must keep covering; guards against silent
    /// truncation when the fixture is refreshed from upstream.
    private static let requiredScenarioIDs = [
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

    // MARK: - Corpus integrity

    func testCorpusIsPresentAndWellFormed() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1, "algorithm_version changed — re-review parity before refreshing the fixture")
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.allCases.map { $0.rawValue })

        let ids = Set(corpus.scenarios.map { $0.id })
        for required in Self.requiredScenarioIDs {
            XCTAssertTrue(ids.contains(required), "corpus is missing scenario \(required) — see docs/parity-corpus.md")
        }

        for scenario in corpus.scenarios {
            XCTAssertEqual(
                scenario.palette.map { $0.index ?? -1 },
                Array(0..<scenario.palette.count),
                "scenario \(scenario.id): palette indices must be dense and 0-based"
            )
            XCTAssertEqual(
                scenario.expected.scores.map { $0.index },
                Array(0..<scenario.palette.count),
                "scenario \(scenario.id): expected scores must cover every candidate"
            )
            XCTAssertFalse(
                makeWeights(scenario).activeConditions.isEmpty,
                "scenario \(scenario.id): at least one positive canonical weight is required"
            )
        }
    }

    // MARK: - Scorer parity

    func testScorerScoresMatchCorpusPerCandidate() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let palette = try makePalette(scenario)
            let target = makeTarget(scenario)
            let weights = makeWeights(scenario)

            for expected in scenario.expected.scores {
                let result = scorer.score(candidate: palette[expected.index], target: target, weights: weights)
                switch (result, expected.numericScore) {
                case (.excluded, nil):
                    break
                case (.score(let value), .some(let recorded)):
                    XCTAssertEqual(
                        value,
                        recorded,
                        accuracy: 1e-12,
                        "scenario \(scenario.id): candidate \(expected.index) score mismatch"
                    )
                case (.excluded, .some(let recorded)):
                    XCTFail("scenario \(scenario.id): candidate \(expected.index) was excluded but corpus recorded \(recorded)")
                case (.score(let value), nil):
                    XCTFail("scenario \(scenario.id): candidate \(expected.index) scored \(value) but corpus recorded exclusion")
                }
            }
        }
    }

    /// Exclusion semantics: a missing measurement on a positive-weight channel
    /// excludes a candidate — it is never scored as zero brightness — while a
    /// missing measurement on a zero-weight channel neither excludes nor
    /// contributes. A target missing a positive-weight channel excludes every
    /// candidate.
    func testMissingMeasurementsAreExcludedNeverTreatedAsZero() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        let missingCandidate = try scenario("missing-candidate-excluded", in: corpus)
        let excludedPalette = try makePalette(missingCandidate)
        XCTAssertEqual(
            scorer.score(
                candidate: excludedPalette[0],
                target: makeTarget(missingCandidate),
                weights: makeWeights(missingCandidate)
            ),
            .excluded,
            "candidate 0 matches every measured channel but lacks lps (positive weight): must be excluded, not zero"
        )
        XCTAssertEqual(missingCandidate.expected.selectedIndex, 1)

        let zeroWeight = try scenario("zero-weight-channel-missing", in: corpus)
        let zeroWeightPalette = try makePalette(zeroWeight)
        guard case .score = scorer.score(
            candidate: zeroWeightPalette[0],
            target: makeTarget(zeroWeight),
            weights: makeWeights(zeroWeight)
        ) else {
            return XCTFail("candidate 0 lacks blue but blue has zero weight: must not be excluded")
        }
        XCTAssertEqual(zeroWeight.expected.tiedIndices, [0, 1])

        let missingTarget = try scenario("missing-target-excluded", in: corpus)
        let missingTargetPalette = try makePalette(missingTarget)
        for color in missingTargetPalette {
            XCTAssertEqual(
                scorer.score(candidate: color, target: makeTarget(missingTarget), weights: makeWeights(missingTarget)),
                .excluded,
                "target is missing white (positive weight): every candidate must be excluded"
            )
        }
        XCTAssertNil(missingTarget.expected.selectedIndex)
    }

    /// Unknown light-source keys in the weights map (here `ultraviolet`) are
    /// ignored: they neither exclude candidates nor contribute to the score,
    /// so the outcome matches the same scenario without the unknown key.
    func testUnknownLightSourceWeightKeysAreIgnored() throws {
        let corpus = try loadCorpus()
        let scenario = try self.scenario("unknown-weight-ignored", in: corpus)
        XCTAssertTrue(
            scenario.weights.keys.contains("ultraviolet"),
            "corpus scenario changed — it must keep exercising an unknown light-source weight"
        )

        let weights = makeWeights(scenario)
        XCTAssertEqual(weights.activeConditions, LightingCondition.allCases)
        XCTAssertEqual(scenario.expected.selectedIndex, 2)

        let baseline = try self.scenario("distinct-errors", in: corpus)
        XCTAssertEqual(
            scenario.expected.scores,
            baseline.expected.scores,
            "the unknown weight key must not change any recorded score"
        )
    }

    // MARK: - Tie-breaking parity

    /// Ties must resolve exactly like the server's `earliest-index-wins`
    /// policy: the winner is the first palette index among the lowest-scored
    /// candidates, and `tie_broke` is true precisely when that group is larger
    /// than one.
    func testTieBreakingMatchesEarliestIndexWinsPolicy() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            guard let tieBroke = scenario.expected.tieBroke,
                  scenario.expected.selectedIndex != nil
            else { continue } // no-selection scenarios are asserted separately

            let palette = try makePalette(scenario)
            let target = makeTarget(scenario)
            let weights = makeWeights(scenario)

            var eligibleScores: [(index: Int, score: Double)] = []
            for (index, color) in palette.enumerated() {
                if case .score(let value) = scorer.score(candidate: color, target: target, weights: weights) {
                    eligibleScores.append((index, value))
                }
            }

            var minimum = Double.infinity
            for entry in eligibleScores where entry.score < minimum {
                minimum = entry.score
            }
            XCTAssertFalse(minimum.isInfinite, "scenario \(scenario.id): every candidate excluded but a selection was expected")

            let tiedIndices = eligibleScores
                .filter { abs($0.score - minimum) <= 1e-12 }
                .map { $0.index }

            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, "scenario \(scenario.id): tied candidate set mismatch")
            XCTAssertEqual(
                tiedIndices.first,
                scenario.expected.selectedIndex,
                "scenario \(scenario.id): the earliest tied index must win"
            )
            XCTAssertEqual(
                tieBroke,
                tiedIndices.count > 1,
                "scenario \(scenario.id): tie_broke flag does not reflect the tie group size"
            )
        }
    }

    // MARK: - Solver selection parity

    /// Runs every corpus scenario through `CompositionSolver`'s production
    /// fast path (the default `WeightedSquaredErrorScorer`) on a 1×1 grid and
    /// asserts the selected palette color, its hex, and the recorded error
    /// match the server's expectation exactly — including scenarios where
    /// every candidate is excluded and no selection exists.
    func testSolverFastPathSelectionMatchesCorpus() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            // The corpus models "target missing a positive-weight channel" at
            // the scorer level (every candidate excluded). The solver always
            // receives a concrete brightness grid per active condition, so
            // absence is not representable there; those scenarios are covered
            // by testMissingMeasurementsAreExcludedNeverTreatedAsZero.
            let target = makeTarget(scenario)
            let weights = makeWeights(scenario)
            let targetMissesActiveChannel = weights.activeEntries.contains { entry in
                target.value(for: entry.condition) == nil
            }
            if targetMissesActiveChannel { continue }

            let palette = try makePalette(scenario)
            let result = try CompositionSolver(scorer: WeightedSquaredErrorScorer())
                .solve(
                    palette: palette,
                    sourceGrids: makeSourceGrids(target: target, weights: weights),
                    weights: weights
                )

            let cell = result.colorIndex(x: 0, y: 0)
            if let expectedIndex = scenario.expected.selectedIndex {
                let selected = try XCTUnwrap(
                    cell,
                    "scenario \(scenario.id): expected selection \(expectedIndex) but the solver matched nothing"
                )
                XCTAssertEqual(palette[selected].id, expectedIndex, "scenario \(scenario.id): wrong color selected")
                XCTAssertEqual(
                    scenario.palette[selected].hexColor,
                    scenario.expected.selectedHexColor,
                    "scenario \(scenario.id): selected hex mismatch"
                )
                let expectedError = try XCTUnwrap(scenario.expected.error, "scenario \(scenario.id): expected an error value")
                XCTAssertEqual(
                    result.error(x: 0, y: 0),
                    expectedError,
                    accuracy: 1e-12,
                    "scenario \(scenario.id): winning error mismatch"
                )
            } else {
                XCTAssertNil(
                    cell,
                    "scenario \(scenario.id): expected no selection but the solver picked \(String(describing: cell))"
                )
                XCTAssertEqual(
                    result.error(x: 0, y: 0),
                    Double.infinity,
                    "scenario \(scenario.id): an unmatched cell must record infinite error"
                )
                XCTAssertEqual(result.unmatchedCellCount, 1, "scenario \(scenario.id): exactly one unmatched cell expected")
            }
        }
    }

    // MARK: - Corpus loading and conversion

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parity_corpus.json")
        do {
            let data = try Data(contentsOf: fixtureURL)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(ParityCorpus.self, from: data)
        } catch {
            XCTFail("parity corpus fixture could not be loaded from \(fixtureURL.path): \(error)")
            throw error
        }
    }

    private func scenario(_ id: String, in corpus: ParityCorpus) throws -> ParityScenario {
        try XCTUnwrap(corpus.scenarios.first { $0.id == id }, "corpus is missing scenario \(id)")
    }

    /// Builds the solver's domain palette in corpus order. The corpus index
    /// becomes the `PaletteColor` id so selections compare directly, and
    /// non-canonical channel keys are dropped exactly like `PaletteColorDTO.toDomain()`.
    private func makePalette(_ scenario: ParityScenario) throws -> [PaletteColor] {
        var palette: [PaletteColor] = []
        for (position, vector) in scenario.palette.enumerated() {
            let hex = vector.hexColor ?? "#000000"
            palette.append(
                PaletteColor(
                    id: vector.index ?? position,
                    hex: hex,
                    rgb: try XCTUnwrap(RGBColor(hex: hex), "corpus hex \(hex) is not a parseable #RRGGBB value"),
                    responses: Self.domainResponses(vector.channels)
                )
            )
        }
        return palette
    }

    private func makeTarget(_ scenario: ParityScenario) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in scenario.target.channels {
            if let condition = LightingCondition(rawValue: key) {
                brightness[condition] = value
            }
        }
        return TargetResponseVector(brightness)
    }

    /// Maps the corpus weights onto the app's canonical `ChannelWeights`;
    /// unknown light-source keys (e.g. `ultraviolet`) are dropped by design.
    private func makeWeights(_ scenario: ParityScenario) -> ChannelWeights {
        func weight(_ key: String) -> Double { scenario.weights[key] ?? 0 }
        return ChannelWeights(
            white: weight("white"),
            red: weight("red"),
            green: weight("green"),
            blue: weight("blue"),
            lps: weight("lps")
        )
    }

    /// One 1×1 source grid per active condition, filled with the target's
    /// brightness — the shape the app feeds the solver for a single cell.
    private func makeSourceGrids(
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid] {
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for entry in weights.activeEntries {
            grids[entry.condition] = BrightnessGrid(
                width: 1,
                height: 1,
                fill: target.value(for: entry.condition) ?? 0
            )
        }
        return grids
    }

    private static func domainResponses(_ channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, brightness) in channels {
            if let condition = LightingCondition(rawValue: key) {
                responses[condition] = IlluminationResponse(brightness: brightness)
            }
        }
        return responses
    }
}

// MARK: - Corpus wire model (snake_case JSON from color_matching)

/// Decoded shape of `priv/parity/v1/corpus.json`.
private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let description: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let index: Int?
    let hexColor: String?
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let selectedIndex: Int?
    let selectedHexColor: String?
    let error: Double?
    let scores: [ParityScore]
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

/// One candidate's recorded outcome: a numeric score, or `nil` when the
/// server excluded the candidate (recorded as the string `"excluded"`).
private struct ParityScore: Decodable, Equatable {
    let index: Int
    let numericScore: Double?

    enum CodingKeys: String, CodingKey {
        case index
        case score
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        numericScore = try? container.decode(Double.self, forKey: .score)
    }
}
