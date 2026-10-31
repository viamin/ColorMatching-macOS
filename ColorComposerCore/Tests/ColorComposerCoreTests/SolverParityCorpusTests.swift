import XCTest
@testable import ColorComposerCore

/// Client/server solver parity replay against the golden-vector corpus
/// committed by viamin/color_matching (PR #112 there; issue #39 here).
///
/// The corpus is generated deterministically on the server side from
/// `ColorMatching.WeightedSquaredError` + `ColorMatching.IlluminantMatching`
/// (`mix parity.generate`; upstream CI verifies the committed bytes). This
/// test replays every scenario through `WeightedSquaredErrorScorer` and the
/// `CompositionSolver` selection path and asserts the results match the
/// corpus exactly — per-candidate scores, missing-measurement exclusions,
/// weight handling (zero and unknown channels ignored), and earliest-wins
/// tie-breaking — so silent divergence between the two implementations is
/// caught.
///
/// The fixture is a byte-for-byte copy of the server's
/// `priv/parity/v1/corpus.json`; see `docs/solver-parity-corpus.md` for how
/// to refresh it. When the corpus `algorithm_version` bumps, the server's
/// scoring semantics changed and this replay must be re-validated before the
/// fixture is refreshed.
final class SolverParityCorpusTests: XCTestCase {
    private let scorer = WeightedSquaredErrorScorer()

    // MARK: - Corpus metadata

    func testCorpusMetadataMatchesSupportedContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1, "solver semantics changed upstream; see docs/solver-parity-corpus.md")
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
        XCTAssertFalse(corpus.scenarios.isEmpty)
    }

    // MARK: - Scorer replay

    /// Every scenario must replay exactly: per-candidate scores (including
    /// `excluded`), the selected index/hex/error, tie evidence, and the
    /// earliest-index-wins selection derived from the scorer's own results.
    func testScorerReplaysEveryScenarioExactly() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            let weights = Self.channelWeights(scenario.weights)
            let target = Self.targetVector(scenario.target)
            let palette = try Self.palette(scenario.palette)

            let scores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
            Self.assertScores(scores, match: scenario.expected, in: scenario)

            let selection = Self.earliestWinningSelection(scores)
            Self.assertSelection(selection, match: scenario.expected, palette: palette, scores: scores, in: scenario)
        }
    }

    // MARK: - Solver replay

    /// The full `CompositionSolver` selection path (the optimized fast path
    /// used in production) must pick the corpus winner for a single-cell
    /// composition and report the same winning error, excluded count, and
    /// no-selection outcome.
    ///
    /// Scenarios whose *target* is missing a positive-weight channel (the
    /// `missing-target-excluded` case) cannot be expressed as solver source
    /// grids — grids always exist for active conditions — so they are covered
    /// by the scorer replay above alone.
    func testSolverReplaySelectsCorpusWinner() throws {
        let corpus = try loadCorpus()
        let solver = CompositionSolver()

        for scenario in corpus.scenarios {
            let weights = Self.channelWeights(scenario.weights)
            let excludedCount = scenario.expected.scores.filter { $0.score == .excluded }.count

            guard let target = Self.completeTarget(scenario.target, for: weights) else { continue }

            var grids: [LightingCondition: BrightnessGrid] = [:]
            for condition in weights.activeConditions {
                grids[condition] = BrightnessGrid(width: 1, height: 1, fill: target.value(for: condition)!)
            }

            let result = try solver.solve(
                palette: try Self.palette(scenario.palette),
                sourceGrids: grids,
                weights: weights
            )

            XCTAssertEqual(
                result.colorIndices.first ?? nil,
                scenario.expected.selectedIndex,
                "scenario \(scenario.id): solver selection diverged"
            )
            if scenario.expected.selectedIndex == nil {
                XCTAssertEqual(
                    result.errors.first,
                    Double.infinity,
                    "scenario \(scenario.id): unmatched cell must report infinite error"
                )
            } else {
                XCTAssertEqual(
                    result.errors.first ?? .nan,
                    try XCTUnwrap(scenario.expected.error),
                    accuracy: 0,
                    "scenario \(scenario.id): solver winning error diverged"
                )
            }
            XCTAssertEqual(
                result.excludedCandidateCount,
                excludedCount,
                "scenario \(scenario.id): excluded-candidate diagnostics diverged"
            )
        }
    }

    // MARK: - Corpus loading

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parity/v1/corpus.json")
        let data = try Data(contentsOf: fixtureURL)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: data)
    }

    // MARK: - Corpus → domain mapping

    /// Weight maps carry only the channels they mention; unknown light
    /// sources (like the corpus's `ultraviolet`) are silently dropped, exactly
    /// like the server's `filter_weights/1`.
    private static func channelWeights(_ raw: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: raw["white"] ?? 0,
            red: raw["red"] ?? 0,
            green: raw["green"] ?? 0,
            blue: raw["blue"] ?? 0,
            lps: raw["lps"] ?? 0
        )
    }

    /// Channels absent from the map are absent from the vector — "missing"
    /// stays distinguishable from "measured as zero brightness".
    private static func targetVector(_ vector: ParityVector) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in vector.channels {
            if let condition = LightingCondition(rawValue: key) {
                brightness[condition] = value
            }
        }
        return TargetResponseVector(brightness)
    }

    private static func palette(_ vectors: [ParityVector]) throws -> [PaletteColor] {
        try vectors.enumerated().map { index, vector in
            var responses: [LightingCondition: IlluminationResponse] = [:]
            for (key, value) in vector.channels {
                if let condition = LightingCondition(rawValue: key) {
                    responses[condition] = IlluminationResponse(brightness: value)
                }
            }
            guard let rgb = RGBColor(hex: vector.hexColor) else {
                throw XCTSkip("corpus hex \(vector.hexColor) is unparseable")
            }
            return PaletteColor(id: index, hex: vector.hexColor, rgb: rgb, responses: responses)
        }
    }

    /// The target as solver source grids: only when every positive-weight
    /// channel is measured on the target itself.
    private static func completeTarget(
        _ vector: ParityVector,
        for weights: ChannelWeights
    ) -> TargetResponseVector? {
        let target = targetVector(vector)
        let complete = weights.activeConditions.allSatisfy { target.value(for: $0) != nil }
        return complete ? target : nil
    }

    // MARK: - Corpus semantics

    /// Mirrors `ColorMatching.IlluminantMatching.best_match/4`: the lowest
    /// score wins, ties go to the earliest index, and a palette with no
    /// scorable candidate selects nothing.
    private static func earliestWinningSelection(_ scores: [ScorerResult]) -> (index: Int, score: Double)? {
        var best: (index: Int, score: Double)?
        for (index, result) in scores.enumerated() {
            if case .score(let value) = result, value < (best?.score ?? .infinity) {
                best = (index, value)
            }
        }
        return best
    }

    private static func tiedIndices(_ scores: [ScorerResult], at score: Double) -> [Int] {
        scores.enumerated().compactMap { index, result in
            guard case .score(let value) = result, value == score else { return nil }
            return index
        }
    }

    // MARK: - Corpus assertions

    private static func assertScores(
        _ scores: [ScorerResult],
        match expected: ParityExpected,
        in scenario: ParityScenario
    ) {
        XCTAssertEqual(
            expected.scores.count,
            scores.count,
            "scenario \(scenario.id): corpus score count must match palette size"
        )
        guard expected.scores.count == scores.count else { return }
        XCTAssertEqual(
            expected.scores.map(\.index),
            Array(scores.indices),
            "scenario \(scenario.id): corpus scores must cover the palette in order"
        )

        for (index, result) in scores.enumerated() {
            let corpusScore = expected.scores[index].score
            switch (result, corpusScore) {
            case (.excluded, .excluded):
                continue
            case (.score(let value), .value(let expectedValue)):
                XCTAssertEqual(
                    value,
                    expectedValue,
                    accuracy: 0,
                    "scenario \(scenario.id): candidate \(index) score diverged"
                )
            default:
                XCTFail(
                    "scenario \(scenario.id): candidate \(index) scored \(result) but corpus expects \(corpusScore)"
                )
            }
        }
    }

    private static func assertSelection(
        _ selection: (index: Int, score: Double)?,
        match expected: ParityExpected,
        palette: [PaletteColor],
        scores: [ScorerResult],
        in scenario: ParityScenario
    ) {
        if let selection {
            let winner = palette[selection.index]
            XCTAssertEqual(
                expected.selectedIndex,
                selection.index,
                "scenario \(scenario.id): selection diverged"
            )
            XCTAssertEqual(
                expected.selectedHexColor,
                winner.hex,
                "scenario \(scenario.id): selected hex color diverged"
            )
            XCTAssertEqual(
                expected.error ?? .nan,
                selection.score,
                accuracy: 0,
                "scenario \(scenario.id): winning error diverged"
            )
            let replayedTies = tiedIndices(scores, at: selection.score)
            XCTAssertEqual(
                expected.tieBroke,
                replayedTies.count > 1,
                "scenario \(scenario.id): tie evidence diverged"
            )
            XCTAssertEqual(
                expected.tiedIndices,
                replayedTies,
                "scenario \(scenario.id): tied indices diverged"
            )
        } else {
            XCTAssertNil(expected.selectedIndex, "scenario \(scenario.id): expected no selection")
            XCTAssertNil(expected.selectedHexColor, "scenario \(scenario.id): expected no selected hex")
            XCTAssertNil(expected.error, "scenario \(scenario.id): expected no winning error")
            XCTAssertNil(expected.tieBroke, "scenario \(scenario.id): expected no tie evidence")
            XCTAssertTrue(expected.tiedIndices.isEmpty, "scenario \(scenario.id): expected no tied indices")
        }
    }

    // MARK: - Wire types (corpus JSON)

    private struct ParityCorpus: Codable {
        let algorithmVersion: Int
        let scorer: String
        let selection: String
        let missingPolicy: String
        let lightSources: [String]
        let scenarios: [ParityScenario]
    }

    private struct ParityScenario: Codable {
        let id: String
        let description: String
        let weights: [String: Double]
        let target: ParityVector
        let palette: [ParityVector]
        let expected: ParityExpected
    }

    private struct ParityVector: Codable {
        let index: Int?
        let hexColor: String
        let channels: [String: Double]
    }

    private struct ParityExpected: Codable {
        struct Scored: Codable {
            let index: Int
            let score: ParityScore
        }

        let scores: [Scored]
        let selectedIndex: Int?
        let selectedHexColor: String?
        let error: Double?
        let tieBroke: Bool?
        let tiedIndices: [Int]
    }
}

/// A corpus score entry: a JSON number, or the string `"excluded"`.
private enum ParityScore: Equatable {
    case value(Double)
    case excluded
}

extension ParityScore: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let excluded = try? container.decode(String.self), excluded == "excluded" {
            self = .excluded
        } else {
            self = .value(try container.decode(Double.self))
        }
    }
}
