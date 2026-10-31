import XCTest
@testable import ColorComposerCore

/// One committed parity scenario replayed through the Swift scorer.
private struct ScenarioReplay {
    let palette: [PaletteColor]
    let weights: ChannelWeights
    let target: TargetResponseVector
    let scores: [ScorerResult]
    let bestIndex: Int?
    let bestScore: Double?

    /// Indices whose score equals the winning score bit-for-bit — the same
    /// recomputation the Elixir corpus test performs.
    func tiedIndices() -> [Int] {
        guard let bestScore else { return [] }
        return scores.enumerated().compactMap { index, result in
            guard case .score(let value) = result, value == bestScore else { return nil }
            return index
        }
    }
}

/// Replays the committed golden-vector corpus from the `color_matching`
/// service through `WeightedSquaredErrorScorer` and the `CompositionSolver`
/// fast path, asserting exact agreement.
///
/// The corpus is the parity contract shared with the Elixir solver
/// (`ColorMatching.WeightedSquaredError` + `IlluminantMatching.best_match/4`);
/// any divergence in missing-measurement exclusion, tie-breaking, or channel
/// weighting shows up here as a mismatch. Corpus values are dyadic rationals,
/// so scores compare with exact double equality — no tolerance. See
/// `docs/solver-parity-corpus.md` for where the corpus lives and how to
/// refresh it.
final class SolverParityCorpusTests: XCTestCase {
    private static let corpusURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/parity/v1/corpus.json")

    // MARK: - Corpus fixture

    func testCorpusIsStampedWithTheCurrentContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
    }

    func testCorpusContainsTiedAndUnselectableScenarios() throws {
        let corpus = try loadCorpus()

        XCTAssertGreaterThanOrEqual(corpus.scenarios.filter { $0.expected.tieBroke == true }.count, 1)
        XCTAssertGreaterThanOrEqual(corpus.scenarios.filter { $0.expected.selectedIndex == nil }.count, 1)
    }

    func testCorpusScenarioIDsAreUniqueAndPaletteIndicesContiguous() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(Set(corpus.scenarios.map(\.id)).count, corpus.scenarios.count)
        for scenario in corpus.scenarios {
            XCTAssertEqual(scenario.palette.compactMap(\.index), Array(scenario.palette.indices), scenario.id)
            XCTAssertEqual(scenario.expected.scores.map(\.index), Array(scenario.palette.indices), scenario.id)
        }
    }

    // MARK: - Scorer parity

    func testScorerPerCandidateScoresMatchCorpusExactly() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            let replay = try replay(scenario)

            XCTAssertEqual(replay.scores.count, scenario.expected.scores.count, scenario.id)
            for expected in scenario.expected.scores {
                guard replay.scores.indices.contains(expected.index) else {
                    XCTFail("\(scenario.id): no candidate at index \(expected.index)")
                    continue
                }
                switch (expected.score, replay.scores[expected.index]) {
                case (.excluded, .excluded):
                    continue
                case (.score(let expectedScore), .score(let score)):
                    XCTAssertEqual(score, expectedScore, "\(scenario.id): candidate \(expected.index)")
                case (.excluded, .score(let score)):
                    XCTFail("\(scenario.id): candidate \(expected.index) expected excluded, scored \(score)")
                case (.score(let expectedScore), .excluded):
                    XCTFail("\(scenario.id): candidate \(expected.index) expected \(expectedScore), was excluded")
                }
            }
        }
    }

    func testScorerSelectionMatchesCorpusIncludingTies() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            let replay = try replay(scenario)
            let expected = scenario.expected

            if let expectedIndex = expected.selectedIndex {
                let index = try XCTUnwrap(replay.bestIndex, "\(scenario.id): expected a selection")
                XCTAssertEqual(index, expectedIndex, scenario.id)
                XCTAssertEqual(
                    replay.palette[index].hex,
                    try XCTUnwrap(expected.selectedHexColor, scenario.id),
                    scenario.id
                )

                let score = try XCTUnwrap(replay.bestScore, scenario.id)
                XCTAssertEqual(score, try XCTUnwrap(expected.error, scenario.id), scenario.id)

                let tied = replay.tiedIndices()
                XCTAssertEqual(tied, expected.tiedIndices, scenario.id)
                XCTAssertEqual(expected.tieBroke, tied.count > 1, scenario.id)
                XCTAssertEqual(tied.first, expectedIndex, scenario.id)
            } else {
                XCTAssertNil(replay.bestIndex, "\(scenario.id): expected no selection")
                XCTAssertNil(expected.error, scenario.id)
                XCTAssertNil(expected.tieBroke, scenario.id)
                XCTAssertEqual(expected.tiedIndices, [], scenario.id)
            }
        }
    }

    func testCorpusExercisesExclusionsZeroWeightChannelsAndUnknownWeights() throws {
        let corpus = try loadCorpus()
        var byID: [String: ParityCorpus.Scenario] = [:]
        for scenario in corpus.scenarios { byID[scenario.id] = scenario }

        let excludedScenario = try XCTUnwrap(byID["missing-candidate-excluded"])
        XCTAssertTrue(excludedScenario.expected.scores.contains { $0.score == .excluded })

        let zeroWeightScenario = try XCTUnwrap(byID["zero-weight-channel-missing"])
        XCTAssertTrue(zeroWeightScenario.expected.tieBroke == true)
        XCTAssertFalse(zeroWeightScenario.expected.scores.contains { $0.score == .excluded })

        let unknownWeightScenario = try XCTUnwrap(byID["unknown-weight-ignored"])
        XCTAssertTrue(unknownWeightScenario.weights.keys.contains("ultraviolet"))
        XCTAssertEqual(unknownWeightScenario.expected.error, byID["distinct-errors"]?.expected.error)
    }

    // MARK: - Solver parity (production fast path)

    /// The solver's contiguous-array fast path must pick the same candidate
    /// the corpus recorded. Scenarios whose *target* lacks a positive-weight
    /// channel cannot be replayed through the solver — the app fails earlier,
    /// at source-grid validation — so they are replayed at the scorer level
    /// only (see `testScorerSelectionMatchesCorpusIncludingTies`).
    func testSolverFastPathSelectionMatchesCorpus() throws {
        let corpus = try loadCorpus()
        var replayed = 0

        for scenario in corpus.scenarios {
            let replay = try replay(scenario)
            let expected = scenario.expected
            let activeConditions = replay.weights.activeConditions
            guard activeConditions.allSatisfy({ replay.target.value(for: $0) != nil }) else { continue }
            replayed += 1

            let grids = try targetGrids(for: activeConditions, from: replay.target, scenario: scenario.id)
            let result = try CompositionSolver().solve(
                palette: replay.palette,
                sourceGrids: grids,
                weights: replay.weights
            )

            XCTAssertEqual(result.colorIndices.first.flatMap { $0 }, expected.selectedIndex, scenario.id)
            if expected.selectedIndex != nil {
                XCTAssertEqual(result.errors.first, try XCTUnwrap(expected.error, scenario.id), scenario.id)
            } else {
                XCTAssertEqual(result.errors.first, Double.infinity, scenario.id)
            }
            let expectedExcluded = expected.scores.filter { $0.score == .excluded }.count
            XCTAssertEqual(result.excludedCandidateCount, expectedExcluded, scenario.id)
        }

        XCTAssertGreaterThanOrEqual(replayed, 11, "nearly every scenario must reach the solver fast path")
    }

    // MARK: - Corpus loading and replay

    private func loadCorpus(file: StaticString = #filePath, line: UInt = #line) throws -> ParityCorpus {
        do {
            let data = try Data(contentsOf: Self.corpusURL)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(ParityCorpus.self, from: data)
        } catch {
            XCTFail("parity corpus is missing or undecodable at \(Self.corpusURL.path): \(error)", file: file, line: line)
            throw error
        }
    }

    private func replay(_ scenario: ParityCorpus.Scenario) throws -> ScenarioReplay {
        let weights = Self.weights(from: scenario.weights)
        let target = try Self.targetVector(from: scenario.target, scenario: scenario.id)
        let palette = try scenario.palette
            .sorted { ($0.index ?? -1) < ($1.index ?? -1) }
            .map { try Self.paletteColor(from: $0, scenario: scenario.id) }

        let scorer = WeightedSquaredErrorScorer()
        var scores: [ScorerResult] = []
        var bestIndex: Int?
        var bestScore: Double?

        for (index, candidate) in palette.enumerated() {
            let result = scorer.score(candidate: candidate, target: target, weights: weights)
            scores.append(result)
            guard case .score(let value) = result, bestScore == nil || value < bestScore! else { continue }
            bestScore = value
            bestIndex = index
        }

        return ScenarioReplay(
            palette: palette,
            weights: weights,
            target: target,
            scores: scores,
            bestIndex: bestIndex,
            bestScore: bestScore
        )
    }

    private func targetGrids(
        for conditions: [LightingCondition],
        from target: TargetResponseVector,
        scenario: String
    ) throws -> [LightingCondition: BrightnessGrid] {
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for condition in conditions {
            let value = try XCTUnwrap(target.value(for: condition), "\(scenario): no grid value for \(condition.rawValue)")
            grids[condition] = BrightnessGrid(width: 1, height: 1, fill: value)
        }
        return grids
    }

    private static func weights(from encoded: [String: Double]) -> ChannelWeights {
        func value(_ condition: LightingCondition) -> Double {
            encoded[condition.rawValue] ?? 0
        }
        return ChannelWeights(
            white: value(.white),
            red: value(.red),
            green: value(.green),
            blue: value(.blue),
            lps: value(.lps)
        )
    }

    private static func targetVector(
        from entry: ParityCorpus.VectorEntry,
        scenario: String
    ) throws -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in entry.channels {
            brightness[try condition(key, scenario: scenario)] = value
        }
        return TargetResponseVector(brightness)
    }

    private static func paletteColor(
        from entry: ParityCorpus.VectorEntry,
        scenario: String
    ) throws -> PaletteColor {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, value) in entry.channels {
            responses[try condition(key, scenario: scenario)] = IlluminationResponse(brightness: value)
        }
        let hex = entry.hexColor
        return PaletteColor(
            id: try XCTUnwrap(entry.index, "\(scenario): palette entry without index"),
            hex: hex,
            rgb: try XCTUnwrap(RGBColor(hex: hex), "\(scenario): unparseable hex \(hex)"),
            responses: responses
        )
    }

    /// Corpus channel keys must all name canonical light sources so a typo in
    /// the fixture can never be silently dropped.
    private static func condition(_ key: String, scenario: String) throws -> LightingCondition {
        guard let condition = LightingCondition(rawValue: key) else {
            throw ParityCorpusError(scenario: scenario, key: key)
        }
        return condition
    }

    private struct ParityCorpusError: Error, CustomStringConvertible {
        let scenario: String
        let key: String
        var description: String { "\(scenario): unknown light source \(key)" }
    }
}

// MARK: - Wire format (upstream `priv/parity/v1/corpus.json`)

private struct ParityCorpus: Codable {
    struct VectorEntry: Codable {
        let index: Int?
        let hexColor: String
        let channels: [String: Double]
    }

    struct ExpectedScore: Codable, Equatable {
        let index: Int
        let score: Score

        /// The corpus encodes excluded candidates as the string `"excluded"`
        /// and scorable candidates as a JSON number.
        enum Score: Equatable {
            case excluded
            case score(Double)
        }

        private enum CodingKeys: String, CodingKey {
            case index, score
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            index = try container.decode(Int.self, forKey: .index)
            score = try container.decode(Score.self, forKey: .score)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(index, forKey: .index)
            try container.encode(score, forKey: .score)
        }
    }

    struct Expected: Codable {
        let scores: [ExpectedScore]
        let selectedIndex: Int?
        let selectedHexColor: String?
        let error: Double?
        let tieBroke: Bool?
        let tiedIndices: [Int]
    }

    struct Scenario: Codable {
        let id: String
        let description: String?
        let weights: [String: Double]
        let target: VectorEntry
        let palette: [VectorEntry]
        let expected: Expected
    }

    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
    let scenarios: [Scenario]
}

extension ParityCorpus.ExpectedScore.Score: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let excluded = try? container.decode(String.self), excluded == "excluded" {
            self = .excluded
        } else {
            self = .score(try container.decode(Double.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .excluded: try container.encode("excluded")
        case .score(let value): try container.encode(value)
        }
    }
}
