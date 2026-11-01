import XCTest
@testable import ColorComposerCore

/// Replays the committed solver-parity corpus published by the
/// `color_matching` server against this package's scorer.
///
/// The corpus is generated upstream by `ColorMatching.Parity.Corpus`
/// (viamin/color_matching#111, committed there at `priv/parity/v1/corpus.json`)
/// and is the shared source of truth that both test suites replay so silent
/// divergence — tie-breaking, missing-measurement exclusion, or channel
/// weighting — is caught. Every scenario pins, per candidate index:
///
/// - the exact weighted squared-error score (or `"excluded"`),
/// - the selected index under earliest-index-wins, *including exact ties*,
/// - the full tied-index set, whether a tie had to be broken, and the
///   winning error.
///
/// Each scenario is also replayed through `CompositionSolver` on a 1×1 grid so
/// the production selection path (not just the scorer) honors the corpus.
///
/// Refresh procedure: see `docs/solver-parity-corpus.md`.
final class SolverParityCorpusTests: XCTestCase {
    // MARK: - Fixture access

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/parity/v1/corpus.json")

    private func loadCorpus(file: StaticString = #filePath, line: UInt = #line) throws -> ParityCorpus {
        let data = try Data(contentsOf: Self.fixtureURL)
        do {
            return try JSONDecoder().decode(ParityCorpus.self, from: data)
        } catch {
            XCTFail("Parity corpus fixture is not decodable: \(error)", file: file, line: line)
            throw error
        }
    }

    // MARK: - Corpus metadata pins

    /// The corpus version and policy header. A change here means upstream
    /// scoring semantics moved and the committed fixture must be refreshed
    /// deliberately (update the pinned scenario ids in this test file).
    func testCorpusHeaderMatchesPinnedVersionAndPolicies() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(Set(corpus.lightSources), Set(LightingCondition.all.map(\.rawValue)))
    }

    /// The committed corpus must carry the pinned scenario set — refreshing it
    /// (or accidentally editing it) is a deliberate act that updates this list.
    func testCorpusCarriesPinnedScenarioSet() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(
            corpus.scenarios.map(\.id),
            [
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
            ]
        )
    }

    /// A corpus refresh that silently drops the edge-case scenarios must fail,
    /// not narrow coverage: ties (including three-way), candidate- and
    /// target-side exclusion, total exclusion, zero-weight-missing channels,
    /// unknown light sources, and an exact match all have to stay represented.
    func testCorpusKeepsCoveringTiesExclusionsAndEdgeCases() throws {
        let corpus = try loadCorpus()
        let byID = Dictionary(uniqueKeysWithValues: corpus.scenarios.map { ($0.id, $0) })

        func keep(_ id: String, _ predicate: (ParityScenario) -> Bool, file: StaticString = #filePath, line: UInt = #line) {
            guard let scenario = byID[id] else {
                return XCTFail("Scenario \(id) missing from corpus", file: file, line: line)
            }
            XCTAssertTrue(predicate(scenario), "Scenario \(id) lost its edge-case shape", file: file, line: line)
        }

        keep("tie-symmetric-around-target") { $0.expected.tieBroke == true && $0.expected.tiedIndices.count == 2 }
        keep("tie-three-way-on-lps") { $0.expected.tieBroke == true && $0.expected.tiedIndices.count == 3 }
        keep("missing-candidate-excluded") { $0.expected.scores.contains { $0.outcome.isExcluded } }
        keep("missing-target-excluded") { $0.expected.selectedIndex == nil && $0.expected.tiedIndices.isEmpty }
        keep("all-excluded") { $0.expected.scores.allSatisfy { $0.outcome.isExcluded } }
        keep("zero-weight-channel-missing") { $0.weights.values.contains(0) && $0.expected.tieBroke == true }
        keep("exact-match-zero-error") { $0.expected.error == 0 }
        keep("unknown-weight-ignored") { $0.weights.keys.contains("ultraviolet") }
    }

    // MARK: - Scorer parity

    /// Per-candidate scores (and exclusions) must match the corpus exactly.
    /// All corpus values are exact binary fractions, so comparison is exact up
    /// to floating-point noise far below any behavioral threshold.
    func testScorerScoresMatchCorpusExactlyIncludingExclusions() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let weights = scenario.mappedWeights
            let target = scenario.target.mappedTargetVector
            let palette = scenario.mappedPalette

            XCTAssertEqual(
                scenario.expected.scores.count, palette.count,
                "\(scenario.id): expected one score per palette candidate"
            )

            // Corpus invariant: palette entries carry their positional index.
            for (position, vector) in scenario.palette.enumerated() {
                XCTAssertEqual(vector.index, position, "\(scenario.id): palette index must match position")
            }

            for (position, candidate) in palette.enumerated() {
                guard let expectedScore = scenario.expected.scores.first(where: { $0.index == position }) else {
                    XCTFail("\(scenario.id): no expected score for index \(position)")
                    continue
                }
                let result = scorer.score(candidate: candidate, target: target, weights: weights)
                assertParity(result: result, expected: expectedScore.outcome, scenario: scenario, index: position)
            }
        }
    }

    /// Selection must match the corpus exactly under earliest-index-wins,
    /// including every tie case: the tied set, whether a tie was broken, the
    /// selected index, its hex color, and the winning error.
    func testSelectionMatchesCorpusIncludingTieBreaking() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let replayed = replaySelection(of: scenario, using: scorer)
            let expected = scenario.expected

            XCTAssertEqual(
                replayed.selectedIndex, expected.selectedIndex,
                "\(scenario.id): selected index"
            )
            XCTAssertEqual(
                replayed.tiedIndices, expected.tiedIndices,
                "\(scenario.id): tied index set"
            )
            XCTAssertEqual(
                replayed.tieBroke, expected.tieBroke,
                "\(scenario.id): tie_broke (null when nothing was selected)"
            )
            if let selected = expected.selectedIndex {
                let hex = scenario.palette.first { $0.index == selected }?.hexColor
                XCTAssertEqual(hex, expected.selectedHexColor, "\(scenario.id): selected hex color")
                XCTAssertEqual(
                    replayed.error ?? 0, expected.error ?? -1, accuracy: 1e-12,
                    "\(scenario.id): winning error"
                )
            } else {
                XCTAssertNil(expected.error, "\(scenario.id): error must be null without a selection")
                XCTAssertNil(expected.selectedHexColor, "\(scenario.id): hex must be null without a selection")
            }
        }
    }

    /// Unknown light-source keys in the weights map (e.g. `ultraviolet`) must
    /// be ignored exactly like the server does — never treated as a required
    /// channel, never contributing to the score.
    func testUnknownLightSourceKeysAreIgnoredWhenMappingWeights() throws {
        let corpus = try loadCorpus()
        let scenario = try XCTUnwrap(
            corpus.scenarios.first { $0.id == "unknown-weight-ignored" },
            "Pinned scenario unknown-weight-ignored is missing"
        )

        let mapped = scenario.mappedWeights

        // Only canonical conditions survive the mapping; `ultraviolet` — a
        // positive weight in the raw corpus — is dropped entirely.
        XCTAssertEqual(mapped.activeConditions, LightingCondition.all)
        XCTAssertEqual(scenario.weights["ultraviolet"], 3.0)

        // And dropping it must reproduce the distinct-errors expectations
        // verbatim (that scenario uses the same vectors with known keys only).
        XCTAssertEqual(
            scenario.expected.scores.map(\.outcome),
            corpus.scenarios.first { $0.id == "distinct-errors" }?.expected.scores.map(\.outcome)
        )
    }

    // MARK: - Solver parity (production selection path)

    /// The same corpus decisions must come out of `CompositionSolver` — the
    /// production earliest-wins selection — on a 1×1 grid: the selected index,
    /// the winning error, and the excluded-candidate count. Scenarios whose
    /// *target* lacks a positively-weighted channel cannot be expressed as a
    /// source grid (the solver requires every active channel) and are covered
    /// by the scorer-level tests above.
    func testSolverReplayMatchesCorpusSelections() throws {
        let corpus = try loadCorpus()
        let solver = CompositionSolver() // default WeightedSquaredErrorScorer

        for scenario in corpus.scenarios {
            let weights = scenario.mappedWeights
            let active = weights.activeConditions
            guard active.allSatisfy({ scenario.target.channels[$0.rawValue] != nil }) else { continue }

            let grids: [LightingCondition: BrightnessGrid] = Dictionary(
                uniqueKeysWithValues: active.map { condition in
                    (condition, BrightnessGrid(width: 1, height: 1, fill: scenario.target.channels[condition.rawValue]!))
                }
            )
            let result = try solver.solve(
                palette: scenario.mappedPalette,
                sourceGrids: grids,
                weights: weights
            )

            let expected = scenario.expected
            XCTAssertEqual(
                result.colorIndex(x: 0, y: 0), expected.selectedIndex,
                "\(scenario.id): solver selection"
            )
            XCTAssertEqual(
                result.excludedCandidateCount,
                expected.scores.filter { $0.outcome.isExcluded }.count,
                "\(scenario.id): excluded candidate count"
            )
            if let selected = expected.selectedIndex {
                XCTAssertEqual(
                    result.error(x: 0, y: 0), expected.error ?? -1, accuracy: 1e-12,
                    "\(scenario.id): solver error"
                )
                XCTAssertEqual(
                    result.palette[selected].hex,
                    expected.selectedHexColor,
                    "\(scenario.id): solver selected hex"
                )
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinity, "\(scenario.id): no selection implies infinite error")
            }
        }
    }

    // MARK: - Replay helpers

    private struct SelectionReplay {
        var selectedIndex: Int?
        var tiedIndices: [Int]
        var tieBroke: Bool?
        var error: Double?
    }

    /// Replays the corpus selection policy: rank every candidate with the
    /// scorer, drop exclusions, pick the minimum score with earliest index
    /// winning ties — the policy documented in the corpus header
    /// (`selection: "earliest-index-wins"`).
    private func replaySelection(of scenario: ParityScenario, using scorer: WeightedSquaredErrorScorer) -> SelectionReplay {
        let weights = scenario.mappedWeights
        let target = scenario.target.mappedTargetVector

        var ranked: [(index: Int, score: Double)] = []
        for (index, candidate) in scenario.mappedPalette.enumerated() {
            if case .score(let value) = scorer.score(candidate: candidate, target: target, weights: weights) {
                ranked.append((index, value))
            }
        }

        guard let best = ranked.map(\.score).min() else {
            return SelectionReplay(selectedIndex: nil, tiedIndices: [], tieBroke: nil, error: nil)
        }
        let tied = ranked.filter { $0.score == best }.map(\.index)
        return SelectionReplay(
            selectedIndex: tied.first,
            tiedIndices: tied,
            tieBroke: tied.count > 1,
            error: best
        )
    }

    private func assertParity(
        result: ScorerResult,
        expected: ParityScoreOutcome,
        scenario: ParityScenario,
        index: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (result, expected) {
        case (.excluded, .excluded):
            return
        case (.score(let value), .score(let expectedValue)):
            XCTAssertEqual(
                value, expectedValue, accuracy: 1e-12,
                "\(scenario.id): score mismatch at candidate \(index)",
                file: file, line: line
            )
        case (.excluded, .score(let expectedValue)):
            XCTFail(
                "\(scenario.id): candidate \(index) was excluded, expected score \(expectedValue)",
                file: file, line: line
            )
        case (.score(let value), .excluded):
            XCTFail(
                "\(scenario.id): candidate \(index) scored \(value), expected exclusion",
                file: file, line: line
            )
        }
    }
}

// MARK: - Corpus wire model

/// Decodable mirror of the committed corpus JSON. Kept private to the test
/// target; the corpus is consumed as data, never as product code.
private struct ParityCorpus: Codable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case lightSources = "light_sources"
        case missingPolicy = "missing_policy"
        case scorer
        case selection
        case scenarios
    }
}

private struct ParityScenario: Codable {
    let id: String
    let descriptionText: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpectation

    enum CodingKeys: String, CodingKey {
        case id
        case descriptionText = "description"
        case palette
        case target
        case weights
        case expected
    }
}

private struct ParityVector: Codable {
    let index: Int?
    let hexColor: String?
    let channels: [String: Double]

    enum CodingKeys: String, CodingKey {
        case index
        case hexColor = "hex_color"
        case channels
    }
}

private struct ParityExpectation: Codable {
    let scores: [ParityExpectedScore]
    let selectedIndex: Int?
    let selectedHexColor: String?
    let tieBroke: Bool?
    let tiedIndices: [Int]
    let error: Double?

    enum CodingKeys: String, CodingKey {
        case scores
        case selectedIndex = "selected_index"
        case selectedHexColor = "selected_hex_color"
        case tieBroke = "tie_broke"
        case tiedIndices = "tied_indices"
        case error
    }
}

/// A per-candidate expectation: a numeric score or the string `"excluded"`.
private struct ParityExpectedScore: Codable {
    let index: Int
    let outcome: ParityScoreOutcome

    enum CodingKeys: String, CodingKey {
        case index
        case score
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        if let value = try? container.decode(Double.self, forKey: .score) {
            outcome = .score(value)
        } else if let text = try? container.decode(String.self, forKey: .score), text == "excluded" {
            outcome = .excluded
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .score, in: container,
                debugDescription: "Expected a numeric score or the string \"excluded\""
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(index, forKey: .index)
        switch outcome {
        case .score(let value): try container.encode(value, forKey: .score)
        case .excluded: try container.encode("excluded", forKey: .score)
        }
    }
}

private enum ParityScoreOutcome: Equatable {
    case score(Double)
    case excluded

    var isExcluded: Bool { self == .excluded }
}

// MARK: - Corpus → domain mapping

/// Mapping mirrors what the app does with server data: canonical light-source
/// keys are kept, unknown keys are ignored, missing keys stay missing (never
/// zero), and ids come from the corpus index.
private extension ParityScenario {
    /// Weights restricted to canonical light sources. Unknown keys (e.g. the
    /// corpus's `ultraviolet`) are dropped, matching `LightingCondition`.
    var mappedWeights: ChannelWeights {
        ChannelWeights(
            white: weights[LightingCondition.white.rawValue] ?? 0,
            red: weights[LightingCondition.red.rawValue] ?? 0,
            green: weights[LightingCondition.green.rawValue] ?? 0,
            blue: weights[LightingCondition.blue.rawValue] ?? 0,
            lps: weights[LightingCondition.lps.rawValue] ?? 0
        )
    }

    var mappedPalette: [PaletteColor] {
        palette.enumerated().map { position, vector in
            PaletteColor(
                id: vector.index ?? position,
                hex: vector.hexColor ?? "#000000",
                rgb: RGBColor(hex: vector.hexColor ?? "#000000") ?? RGBColor(red: 0, green: 0, blue: 0),
                responses: vector.mappedResponses
            )
        }
    }
}

private extension ParityVector {
    /// Brightness keyed by canonical condition; absent channel keys stay
    /// absent so "missing" is distinguishable from "measured zero".
    var mappedResponses: [LightingCondition: IlluminationResponse] {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, value) in channels {
            if let condition = LightingCondition(rawValue: key) {
                responses[condition] = IlluminationResponse(brightness: value)
            }
        }
        return responses
    }

    var mappedTargetVector: TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in channels {
            if let condition = LightingCondition(rawValue: key) {
                brightness[condition] = value
            }
        }
        return TargetResponseVector(brightness)
    }
}
