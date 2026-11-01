import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the golden-vector solver parity corpus committed by the
/// `color_matching` server (viamin/color_matching#111, landed as PR #112)
/// through this package's solver, asserting exact agreement.
///
/// The corpus is the shared source of truth that keeps
/// `WeightedSquaredErrorScorer` (and the `CompositionSolver` fast path) in
/// lockstep with the Elixir `ColorMatching.WeightedSquaredError` solver and
/// the earliest-wins selection of `ColorMatching.IlluminantMatching`. Any
/// mismatch reported here means the client and server have diverged on
/// tie-breaking, missing-measurement exclusion, or channel weighting.
///
/// The fixture is vendored at `Fixtures/parity/v1/corpus.json` next to this
/// test; see `docs/parity-corpus.md` for where it comes from and how to
/// refresh it. Deliberately longer than the ~100-line guideline: the corpus
/// decoding model, the corpus→domain mapping, and the replay assertions all
/// describe one fixture contract, and splitting them would spread that
/// contract across collaborators without reducing any complexity.
final class SolverParityCorpusTests: XCTestCase {
    // MARK: - Corpus decoding model (wire format of the upstream corpus)

    private struct ParityCorpus: Decodable {
        let algorithmVersion: Int
        let scorer: String
        let selection: String
        let missingPolicy: String
        let lightSources: [String]
        let scenarios: [ParityScenario]

        enum CodingKeys: String, CodingKey {
            case algorithmVersion = "algorithm_version"
            case scorer
            case selection
            case missingPolicy = "missing_policy"
            case lightSources = "light_sources"
            case scenarios
        }
    }

    private struct ParityScenario: Decodable {
        let id: String
        let description: String
        let weights: [String: Double]
        let target: ParityVector
        let palette: [ParityVector]
        let expected: ParityExpected
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

    private struct ParityExpected: Decodable {
        let scores: [ParityScoreRow]
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

    private struct ParityScoreRow: Decodable {
        let index: Int
        let score: ParityScoreValue
    }

    /// A score-table entry: a finite error, or the `"excluded"` marker the
    /// corpus uses for missing-measurement exclusions.
    private enum ParityScoreValue: Decodable, Equatable {
        case score(Double)
        case excluded

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                self = .score(value)
            } else if let raw = try? container.decode(String.self), raw == "excluded" {
                self = .excluded
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected a numeric score or the string \"excluded\"."
                )
            }
        }
    }

    // MARK: - Corpus loading

    /// The corpus version this client understands. When the upstream stamp
    /// changes, every expectation in the corpus has moved and this test must
    /// be updated in step (see `docs/parity-corpus.md`).
    private static let supportedAlgorithmVersion = 1

    private static func loadCorpus(file: StaticString = #filePath, line: UInt = #line) throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parity/v1/corpus.json")
        do {
            let data = try Data(contentsOf: fixtureURL)
            return try JSONDecoder().decode(ParityCorpus.self, from: data)
        } catch {
            XCTFail(
                "Parity corpus fixture missing or undecodable at \(fixtureURL.path). "
                    + "Vendor it from viamin/color_matching priv/parity/v1/corpus.json "
                    + "(see docs/parity-corpus.md): \(error)",
                file: file,
                line: line
            )
            throw error
        }
    }

    // MARK: - Corpus metadata

    func testCorpusMetadataMatchesSupportedSolverSemantics() throws {
        let corpus = try Self.loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, Self.supportedAlgorithmVersion)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
    }

    /// The corpus must actually exercise the parity edges it exists for:
    /// intentional ties, missing-measurement exclusions, and cases where no
    /// candidate is selectable. A refreshed corpus that quietly dropped those
    /// families would stop verifying the contract it is committed to.
    func testCorpusCoversTiesExclusionsAndNoSelectionCases() throws {
        let corpus = try Self.loadCorpus()

        XCTAssertTrue(corpus.scenarios.count >= 12, "Expected the full v1 scenario set")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true }, "Corpus lost its tie cases")
        XCTAssertTrue(
            corpus.scenarios.contains { $0.expected.scores.contains { $0.score == .excluded } },
            "Corpus lost its missing-measurement exclusion cases"
        )
        XCTAssertTrue(
            corpus.scenarios.contains { $0.expected.selectedIndex == nil },
            "Corpus lost its no-selection cases"
        )
    }

    // MARK: - Scorer parity

    /// Every scenario: the per-candidate score table, the selected index and
    /// hex color, the winning error, and the tie evidence must match exactly.
    func testScorerReplayMatchesEveryScenarioExactly() throws {
        let corpus = try Self.loadCorpus()

        for scenario in corpus.scenarios {
            try replayScenarioThroughScorer(scenario)
        }
    }

    private func replayScenarioThroughScorer(
        _ scenario: ParityScenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let scorer = WeightedSquaredErrorScorer()
        let weights = Self.channelWeights(from: scenario.weights)
        let target = Self.targetVector(from: scenario.target)
        let palette = try Self.paletteColors(from: scenario.palette)

        let computed = Self.scoreEveryCandidate(palette: palette, target: target, weights: weights)
        XCTAssertEqual(
            scenario.expected.scores.count, palette.count,
            "Scenario \(scenario.id): score table must cover the whole palette",
            file: file, line: line
        )
        assertScoreTablesAgree(scenario: scenario, computed: computed, file: file, line: line)
        assertSelectionAgrees(scenario: scenario, computed: computed, palette: palette, file: file, line: line)
    }

    /// Scores every candidate, mirroring the corpus's per-candidate table.
    private static func scoreEveryCandidate(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> [ParityScoreValue] {
        let scorer = WeightedSquaredErrorScorer()
        return palette.map { color in
            switch scorer.score(candidate: color, target: target, weights: weights) {
            case .score(let value): return .score(value)
            case .excluded: return .excluded
            }
        }
    }

    private func assertScoreTablesAgree(
        scenario: ParityScenario,
        computed: [ParityScoreValue],
        file: StaticString,
        line: UInt
    ) {
        for (position, row) in scenario.expected.scores.enumerated() {
            XCTAssertEqual(
                row.index, position,
                "Scenario \(scenario.id): score rows must be ordered by palette index",
                file: file, line: line
            )
            guard position < computed.count else { continue }
            XCTAssertEqual(computed[position], row.score,
                "Scenario \(scenario.id): candidate \(position) scored \(computed[position]) but corpus says \(row.score)",
                file: file, line: line
            )
            if case .score(let expected) = row.score, case .score(let actual) = computed[position] {
                XCTAssertEqual(actual, expected, accuracy: 1e-12,
                    "Scenario \(scenario.id): candidate \(position) error mismatch",
                    file: file, line: line
                )
            }
        }
    }

    private func assertSelectionAgrees(
        scenario: ParityScenario,
        computed: [ParityScoreValue],
        palette: [PaletteColor],
        file: StaticString,
        line: UInt
    ) {
        let expected = scenario.expected
        var selectedIndex: Int?
        var bestScore = Double.infinity
        for (index, score) in computed.enumerated() {
            guard case .score(let value) = score, value < bestScore else { continue }
            bestScore = value
            selectedIndex = index
        }

        guard let expectedIndex = expected.selectedIndex else {
            XCTAssertNil(selectedIndex,
                "Scenario \(scenario.id): corpus records no selection but Swift selected \(String(describing: selectedIndex))",
                file: file, line: line
            )
            XCTAssertTrue(expected.tiedIndices.isEmpty,
                "Scenario \(scenario.id): no-selection cases carry no tied indices",
                file: file, line: line
            )
            return
        }

        XCTAssertTrue(palette.indices.contains(expectedIndex),
            "Scenario \(scenario.id): selected index out of range",
            file: file, line: line
        )
        XCTAssertEqual(selectedIndex, expectedIndex,
            "Scenario \(scenario.id): selection mismatch (earliest-wins tie-breaking)",
            file: file, line: line
        )
        XCTAssertEqual(palette[expectedIndex].hex, expected.selectedHexColor,
            "Scenario \(scenario.id): selected hex color mismatch",
            file: file, line: line
        )
        if let expectedError = expected.error {
            XCTAssertEqual(bestScore, expectedError, accuracy: 1e-12,
                "Scenario \(scenario.id): winning error mismatch",
                file: file, line: line
            )
        } else {
            XCTFail("Scenario \(scenario.id): selection recorded without an error", file: file, line: line)
        }
        assertTieEvidenceAgrees(scenario: scenario, computed: computed, selectedIndex: selectedIndex,
            file: file, line: line)
    }

    private func assertTieEvidenceAgrees(
        scenario: ParityScenario,
        computed: [ParityScoreValue],
        selectedIndex: Int?,
        file: StaticString,
        line: UInt
    ) {
        let expected = scenario.expected
        guard let winner = selectedIndex, case .score(let winningScore) = computed[winner] else { return }

        let tiedIndices = computed.indices.filter { index in
            guard case .score(let value) = computed[index] else { return false }
            return value == winningScore
        }
        XCTAssertEqual(tiedIndices, expected.tiedIndices,
            "Scenario \(scenario.id): tied index set mismatch",
            file: file, line: line
        )
        XCTAssertEqual(tiedIndices.first, winner,
            "Scenario \(scenario.id): the earliest tied index must win",
            file: file, line: line
        )
        XCTAssertEqual(expected.tieBroke, tiedIndices.count > 1,
            "Scenario \(scenario.id): tie_broke flag mismatch",
            file: file, line: line
        )
    }

    // MARK: - Solver fast-path parity

    /// The same corpus replayed through `CompositionSolver`'s optimized fast
    /// path (the path real compositions take): each scenario becomes a 1×1
    /// output whose per-channel target grid holds the scenario's target
    /// brightness, and the solver's selection, per-cell error, and exclusion
    /// count must match the corpus. Scenarios whose *target* is missing an
    /// active channel cannot be expressed as grids (no source image could
    /// produce them) and are covered by the scorer-level replay above.
    func testSolverFastPathReplayMatchesSelectionsAndExclusions() throws {
        let corpus = try Self.loadCorpus()

        for scenario in corpus.scenarios {
            let weights = Self.channelWeights(from: scenario.weights)
            let target = Self.targetVector(from: scenario.target)
            guard weights.activeConditions.allSatisfy({ target.value(for: $0) != nil }) else { continue }

            let palette = try Self.paletteColors(from: scenario.palette)
            let grids = Self.oneByOneGrids(for: target, activeConditions: weights.activeConditions)
            let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)

            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex,
                "Scenario \(scenario.id): solver fast-path selection mismatch",
                file: #filePath, line: #line
            )
            assertSolverErrorMatches(scenario: scenario, result: result)
            XCTAssertEqual(
                result.excludedCandidateCount,
                scenario.expected.scores.filter { $0.score == .excluded }.count,
                "Scenario \(scenario.id): excluded-candidate count mismatch",
                file: #filePath, line: #line
            )
        }
    }

    private func assertSolverErrorMatches(scenario: ParityScenario, result: CompositionResult) {
        if let expectedError = scenario.expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12,
                "Scenario \(scenario.id): solver fast-path error mismatch",
                file: #filePath, line: #line
            )
        } else {
            XCTAssertEqual(result.error(x: 0, y: 0), Double.infinity,
                "Scenario \(scenario.id): all-excluded cases must record infinite error",
                file: #filePath, line: #line
            )
        }
    }

    // MARK: - Corpus → domain mapping

    /// Only the five canonical light sources participate; unknown keys (the
    /// corpus's `ultraviolet` weight scenario) must be ignored, mirroring the
    /// server's handling of unknown light sources.
    private static func channelWeights(from raw: [String: Double]) -> ChannelWeights {
        func weight(_ condition: LightingCondition) -> Double {
            raw[condition.rawValue] ?? 0
        }
        return ChannelWeights(
            white: weight(.white),
            red: weight(.red),
            green: weight(.green),
            blue: weight(.blue),
            lps: weight(.lps)
        )
    }

    private static func targetVector(from entry: ParityVector) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in entry.channels {
            if let condition = LightingCondition(rawValue: key) {
                brightness[condition] = value
            }
        }
        return TargetResponseVector(brightness)
    }

    private static func paletteColors(from entries: [ParityVector]) throws -> [PaletteColor] {
        try entries.enumerated().map { index, entry in
            guard let rgb = RGBColor(hex: entry.hexColor) else {
                throw NSError(
                    domain: "SolverParityCorpusTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Corpus hex \(entry.hexColor) is not parseable"]
                )
            }
            var responses: [LightingCondition: IlluminationResponse] = [:]
            for (key, value) in entry.channels {
                if let condition = LightingCondition(rawValue: key) {
                    responses[condition] = IlluminationResponse(brightness: value)
                }
            }
            return PaletteColor(id: index, hex: entry.hexColor, rgb: rgb, responses: responses)
        }
    }

    private static func oneByOneGrids(
        for target: TargetResponseVector,
        activeConditions: [LightingCondition]
    ) -> [LightingCondition: BrightnessGrid] {
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for condition in activeConditions {
            grids[condition] = BrightnessGrid(width: 1, height: 1, fill: target.value(for: condition) ?? 0)
        }
        return grids
    }
}
