import XCTest
@testable import ColorComposerCore

/// Solver parity against the committed golden-vector corpus from the
/// `color_matching` service (issue #39).
///
/// The corpus is the parity contract shared with the Elixir server: any
/// divergence in missing-measurement exclusion, tie-breaking, or channel
/// weighting shows up here as a mismatch. It replays every scenario through
/// `WeightedSquaredErrorScorer` exactly like the upstream
/// `ColorMatching.Parity.CorpusTest` does, and additionally drives
/// `CompositionSolver` (its contiguous fast path) with 1×1 grids to pin the
/// end-to-end earliest-wins selection the app actually performs.
///
/// Fixture: `Fixtures/ParityCorpus/v1/corpus.json` — a byte-identical copy of
/// `priv/parity/v1/corpus.json` from viamin/color_matching (see
/// `docs/solver-parity-corpus.md` for provenance and the refresh procedure).
///
/// Scores are compared with exact `Double` equality, mirroring the upstream
/// Elixir test: every corpus value is a dyadic rational, so both
/// implementations must land on the identical bit pattern.
final class SolverParityCorpusTests: XCTestCase {
    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ParityCorpus/v1/corpus.json")

    /// Scenarios the corpus must keep covering: ties (the issue calls out tie
    /// cases explicitly), exclusions, and unknown-channel tolerance.
    private static let requiredScenarioIDs = [
        "tie-symmetric-around-target",
        "tie-duplicate-vectors",
        "tie-three-way-on-lps",
        "missing-candidate-excluded",
        "missing-target-excluded",
        "zero-weight-channel-missing",
        "all-excluded",
        "unknown-weight-ignored",
        "mixed-large-palette"
    ]

    private func loadCorpus() throws -> ParityCorpus {
        do {
            let data = try Data(contentsOf: Self.fixtureURL)
            return try JSONDecoder().decode(ParityCorpus.self, from: data)
        } catch {
            XCTFail("parity corpus fixture is missing or undecodable at \(Self.fixtureURL.path): \(error)")
            throw error
        }
    }

    // MARK: - Corpus contract

    func testCorpusMetadataMatchesTheParityContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1, "corpus algorithm_version changed; re-review parity and refresh the fixture")
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
    }

    func testCorpusKeepsCoveringTiesExclusionsAndNullSelections() throws {
        let corpus = try loadCorpus()
        let scenarios = corpus.scenarios

        XCTAssertGreaterThanOrEqual(scenarios.count, 12)
        XCTAssertEqual(Set(scenarios.map(\.id)).count, scenarios.count, "scenario ids must be unique")

        let ids = Set(scenarios.map(\.id))
        for required in Self.requiredScenarioIDs where !ids.contains(required) {
            XCTFail("corpus no longer contains required scenario '\(required)'")
        }

        XCTAssertGreaterThanOrEqual(scenarios.filter { $0.expected.tieBroke == true }.count, 1, "tie coverage disappeared")
        XCTAssertGreaterThanOrEqual(scenarios.filter { $0.expected.selectedIndex == nil }.count, 1, "null-selection coverage disappeared")
        XCTAssertTrue(
            scenarios.flatMap(\.expected.scores).contains { $0.score == .excluded },
            "exclusion coverage disappeared"
        )
    }

    // MARK: - Replay

    func testReplaysEveryScenarioThroughTheScorerWithExactAgreement() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            replayScorerLevel(scenario)
        }
    }

    func testReplaysEveryScenarioThroughTheCompositionSolverFastPath() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            replaySolverLevel(scenario)
        }
    }

    /// Mirrors `CorpusTest.run_scenario_and_assert/1`: per-candidate scores,
    /// earliest-wins selection, and recomputed tie evidence.
    private func replayScorerLevel(_ scenario: ParityScenario) {
        let weights = Self.makeWeights(scenario.weights)
        let target = Self.makeTarget(scenario.target)
        let palette = Self.makePalette(scenario.palette)
        let scorer = WeightedSquaredErrorScorer()

        let scored = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
        assertScores(scored, match: scenario.expected.scores, scenarioID: scenario.id)

        let best = Self.bestIndex(scored)
        assertSelection(best, in: palette, match: scenario.expected, scenarioID: scenario.id)
        assertTieEvidence(best, in: scored, match: scenario.expected, scenarioID: scenario.id)
    }

    /// Drives `CompositionSolver` (1×1 grids holding the target vector) so the
    /// solver's optimized fast path — the code the app actually runs — is held
    /// to the same selections, errors, and tie-breaking as the corpus.
    private func replaySolverLevel(_ scenario: ParityScenario) {
        let weights = Self.makeWeights(scenario.weights)
        let active = weights.activeEntries

        // A BrightnessGrid cannot represent "missing"; scenarios whose target
        // is itself missing a positive-weight channel (missing-target-excluded)
        // exist to exercise the scorer's exclusion rule and are covered above.
        let targetComplete = active.allSatisfy { scenario.target.channels[$0.condition.rawValue] != nil }
        guard targetComplete else { return }

        let palette = Self.makePalette(scenario.palette)
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for (condition, _) in active {
            grids[condition] = BrightnessGrid(width: 1, height: 1, fill: scenario.target.channels[condition.rawValue]!)
        }

        guard let result = try? CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights) else {
            return XCTFail("\(scenario.id): solver threw on a valid 1×1 replay")
        }
        let selected = result.colorIndex(x: 0, y: 0)
        let cellError = result.error(x: 0, y: 0)

        XCTAssertEqual(selected, scenario.expected.selectedIndex, "\(scenario.id): solver fast-path selection diverged")
        if scenario.expected.selectedIndex == nil {
            XCTAssertEqual(cellError, Double.infinity, "\(scenario.id): unmatched cell must record infinite error")
            XCTAssertEqual(result.unmatchedCellCount, 1, "\(scenario.id): cell must be unmatched")
        } else {
            XCTAssertEqual(Optional(cellError), scenario.expected.error, "\(scenario.id): solver fast-path error diverged")
        }
    }

    // MARK: - Assertion helpers (ports of the upstream Elixir assertions)

    private func assertScores(
        _ scored: [ScorerResult],
        match expected: [ParityScoreEntry],
        scenarioID: String
    ) {
        XCTAssertEqual(scored.count, expected.count, "\(scenarioID): candidate count")

        let sorted = expected.sorted { $0.index < $1.index }
        for (position, result) in scored.enumerated() {
            let entry = sorted[position]
            switch entry.score {
            case .excluded:
                XCTAssertEqual(result, .excluded, "\(scenarioID): candidate \(entry.index) must be excluded")
            case .score(let value):
                guard case .score(let actual) = result else {
                    return XCTFail("\(scenarioID): candidate \(entry.index) expected a score, got .excluded")
                }
                XCTAssertEqual(actual, value, "\(scenarioID): candidate \(entry.index) score diverged")
            }
        }
    }

    private func assertSelection(
        _ best: (index: Int, error: Double)?,
        in palette: [PaletteColor],
        match expected: ParityExpected,
        scenarioID: String
    ) {
        guard let expectedIndex = expected.selectedIndex else {
            XCTAssertNil(best, "\(scenarioID): expected no selection, got \(String(describing: best))")
            return
        }

        guard let chosen = best else {
            return XCTFail("\(scenarioID): expected a selection at index \(expectedIndex), got none")
        }
        XCTAssertEqual(chosen.index, expectedIndex, "\(scenarioID): selected index")
        XCTAssertEqual(palette[expectedIndex].hex, expected.selectedHexColor, "\(scenarioID): selected hex color")
        XCTAssertEqual(Optional(chosen.error), expected.error, "\(scenarioID): selected error")
    }

    private func assertTieEvidence(
        _ best: (index: Int, error: Double)?,
        in scored: [ScorerResult],
        match expected: ParityExpected,
        scenarioID: String
    ) {
        guard let best else {
            XCTAssertNil(expected.tieBroke, "\(scenarioID): tie_broke")
            XCTAssertEqual(expected.tiedIndices, [], "\(scenarioID): tied_indices")
            return
        }

        let recomputed = scored.enumerated().compactMap { position, result -> Int? in
            guard case .score(let value) = result, value == best.error else { return nil }
            return position
        }
        XCTAssertEqual(recomputed, expected.tiedIndices, "\(scenarioID): recomputed tied indices")
        XCTAssertEqual(recomputed.first, expected.selectedIndex, "\(scenarioID): winner must be the earliest tied index")
        XCTAssertEqual(expected.tieBroke, recomputed.count > 1, "\(scenarioID): tie_broke")
    }

    // MARK: - Corpus → domain mapping

    /// Unknown light sources in `weights` (e.g. "ultraviolet") are silently
    /// dropped, mirroring `WeightedSquaredError.filter_weights/1`.
    private static func makeWeights(_ encoded: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: encoded["white"] ?? 0,
            red: encoded["red"] ?? 0,
            green: encoded["green"] ?? 0,
            blue: encoded["blue"] ?? 0,
            lps: encoded["lps"] ?? 0
        )
    }

    /// Absent channel keys stay absent — missing, never zero — exactly like
    /// `CorpusTest.decode_vector/1` maps absent entries to `:missing`.
    private static func makeTarget(_ entry: ParityVector) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in entry.channels {
            if let condition = LightingCondition(rawValue: key) {
                brightness[condition] = value
            }
        }
        return TargetResponseVector(brightness)
    }

    private static func makePalette(_ entries: [ParityVector]) -> [PaletteColor] {
        entries
            .sorted { $0.index ?? 0 < $1.index ?? 0 }
            .map { entry in
                var responses: [LightingCondition: IlluminationResponse] = [:]
                for (key, value) in entry.channels {
                    if let condition = LightingCondition(rawValue: key) {
                        responses[condition] = IlluminationResponse(brightness: value)
                    }
                }
                let hex = entry.hexColor
                return PaletteColor(
                    id: entry.index ?? 0,
                    hex: hex,
                    rgb: RGBColor(hex: hex) ?? RGBColor(red: 0, green: 0, blue: 0),
                    responses: responses
                )
            }
    }

    /// Lowest score with earliest-index tie-breaking, or `nil` when every
    /// candidate is excluded — the client-side mirror of `IlluminantMatching.best_match/4`.
    private static func bestIndex(_ scored: [ScorerResult]) -> (index: Int, error: Double)? {
        var best: (index: Int, error: Double)?
        for (index, result) in scored.enumerated() {
            guard case .score(let value) = result else { continue }
            if value < (best?.error ?? .infinity) {
                best = (index, value)
            }
        }
        return best
    }
}

// MARK: - Corpus wire models

/// Score payload: a JSON number, or the string `"excluded"`.
private enum ParityScore: Equatable {
    case score(Double)
    case excluded
}

private struct ParityScoreEntry: Decodable {
    let index: Int
    let score: ParityScore
}

private struct ParityExpected: Decodable {
    let scores: [ParityScoreEntry]
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

private struct ParityVector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]

    enum CodingKeys: String, CodingKey {
        case index
        case hexColor = "hex_color"
        case channels
    }
}

private struct ParityScenario: Decodable {
    let id: String
    let description: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityCorpus: Decodable {
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

extension ParityScore: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let excluded = try? container.decode(String.self), excluded == "excluded" {
            self = .excluded
        } else {
            self = .score(try container.decode(Double.self))
        }
    }
}
