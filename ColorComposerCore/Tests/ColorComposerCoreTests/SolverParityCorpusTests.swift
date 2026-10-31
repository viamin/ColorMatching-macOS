import Foundation
import XCTest
@testable import ColorComposerCore

/// Solver parity against the golden-vector corpus published by the Elixir
/// service (viamin/color_matching#112, issue #111).
///
/// The corpus is vendored byte-for-byte at
/// `Tests/ColorComposerCoreTests/Fixtures/ParityCorpus/v1/corpus.json` from
/// upstream `priv/parity/v1/corpus.json`. Every scenario carries a palette,
/// a target vector, channel weights, and expected outputs produced by the
/// server's `ColorMatching.WeightedSquaredError` solver: per-candidate
/// scores (or exclusions), the selected index, the winning error, and
/// tie-break evidence. See `docs/solver-parity-corpus.md` for how to
/// refresh the vendored copy.
///
/// All corpus numbers are exact binary fractions, so scores are compared
/// with exact `==` — any disagreement is a real parity break, not noise.
final class SolverParityCorpusTests: XCTestCase {
    // MARK: - Corpus wire model

    private struct ParityCorpus: Codable {
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
        let palette: [Candidate]
        let target: Candidate
        let weights: [String: Double]
        let expected: Expected
    }

    private struct Candidate: Codable {
        let index: Int?
        let hexColor: String
        let channels: [String: Double]

        enum CodingKeys: String, CodingKey {
            case index
            case hexColor = "hex_color"
            case channels
        }
    }

    private struct Expected: Codable {
        let selectedIndex: Int?
        let selectedHexColor: String?
        let error: Double?
        let tieBroke: Bool?
        let tiedIndices: [Int]
        let scores: [ExpectedScore]

        enum CodingKeys: String, CodingKey {
            case selectedIndex = "selected_index"
            case selectedHexColor = "selected_hex_color"
            case error
            case tieBroke = "tie_broke"
            case tiedIndices = "tied_indices"
            case scores
        }
    }

    private struct ExpectedScore: Codable {
        let index: Int
        let outcome: Outcome

        enum CodingKeys: String, CodingKey {
            case index
            case score
        }

        enum Outcome: Equatable {
            case score(Double)
            case excluded
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            index = try container.decode(Int.self, forKey: .index)
            let value = try container.decode(CorpusScoreValue.self, forKey: .score)
            outcome = value.outcome
        }
    }

    /// A corpus score is either a number or the literal string `"excluded"`.
    private enum CorpusScoreValue: Decodable {
        case score(Double)
        case excluded

        var outcome: ExpectedScore.Outcome {
            switch self {
            case .score(let value): return .score(value)
            case .excluded: return .excluded
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                self = .score(value)
            } else if let string = try? container.decode(String.self), string == "excluded" {
                self = .excluded
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: #"score must be a number or "excluded""#
                )
            }
        }
    }

    // MARK: - Corpus loading

    private func loadCorpus(file: StaticString = #filePath, line: UInt = #line) throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ParityCorpus/v1/corpus.json")
        let data = try Data(contentsOf: fixtureURL)
        do {
            return try JSONDecoder().decode(ParityCorpus.self, from: data)
        } catch {
            XCTFail("parity corpus fixture failed to decode: \(error)", file: file, line: line)
            throw error
        }
    }

    private func scenario(_ id: String, in corpus: ParityCorpus) throws -> Scenario {
        try XCTUnwrap(corpus.scenarios.first { $0.id == id }, "corpus must contain scenario \(id)")
    }

    // MARK: - Corpus → domain conversion

    /// Unknown light-source keys (e.g. the corpus's "ultraviolet") are
    /// ignored, matching the client's fixed `ChannelWeights` fields.
    private func makeWeights(_ raw: [String: Double]) -> ChannelWeights {
        var weights = ChannelWeights()
        for (key, value) in raw {
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

    private func makeColor(_ candidate: Candidate) throws -> PaletteColor {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, value) in candidate.channels {
            guard let condition = LightingCondition(rawValue: key) else { continue }
            responses[condition] = IlluminationResponse(brightness: value)
        }
        let rgb = try XCTUnwrap(RGBColor(hex: candidate.hexColor), "unparseable hex \(candidate.hexColor)")
        return PaletteColor(
            id: candidate.index ?? 0,
            hex: candidate.hexColor,
            rgb: rgb,
            responses: responses
        )
    }

    private func makeTarget(_ candidate: Candidate) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in candidate.channels {
            guard let condition = LightingCondition(rawValue: key) else { continue }
            brightness[condition] = value
        }
        return TargetResponseVector(brightness)
    }

    // MARK: - Replay

    private struct Replay {
        let scores: [ScorerResult]
        let selectedIndex: Int?
        let bestScore: Double?
        let tiedIndices: [Int]
        let tieBroke: Bool?
    }

    /// Replays one scenario through `WeightedSquaredErrorScorer` with the
    /// corpus selection policy: strictly-less comparison, so the earliest
    /// candidate wins an exact tie.
    private func replay(_ scenario: Scenario) throws -> Replay {
        let palette = try scenario.palette.map(makeColor)
        let target = makeTarget(scenario.target)
        let weights = makeWeights(scenario.weights)
        let scorer = WeightedSquaredErrorScorer()

        let scores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        var best: (index: Int, score: Double)?
        for (index, result) in scores.enumerated() {
            guard case .score(let value) = result else { continue }
            if value < (best?.score ?? .infinity) {
                best = (index, value)
            }
        }

        guard let winner = best else {
            return Replay(scores: scores, selectedIndex: nil, bestScore: nil, tiedIndices: [], tieBroke: nil)
        }
        let tied = scores.enumerated().compactMap { index, result -> Int? in
            guard case .score(let value) = result, value == winner.score else { return nil }
            return index
        }
        return Replay(
            scores: scores,
            selectedIndex: winner.index,
            bestScore: winner.score,
            tiedIndices: tied,
            tieBroke: tied.count > 1
        )
    }

    // MARK: - Full-corpus parity

    func testCorpusMetadataMatchesClientSolverContract() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1, "corpus stamp must match the mirrored solver version")
        XCTAssertEqual(
            Set(corpus.lightSources),
            Set(LightingCondition.allCases.map(\.rawValue)),
            "corpus light sources must be exactly the client's lighting conditions"
        )
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertTrue(corpus.scorer.hasSuffix("WeightedSquaredError"), "unexpected scorer \(corpus.scorer)")
        XCTAssertGreaterThanOrEqual(corpus.scenarios.count, 12, "corpus appears truncated")

        for scenario in corpus.scenarios {
            XCTAssertEqual(
                Set(scenario.expected.scores.map(\.index)),
                Set(scenario.palette.indices),
                "[\(scenario.id)] every candidate must carry an expected score"
            )
        }
    }

    func testEveryScenarioMatchesExpectedOutputsExactly() throws {
        let corpus = try loadCorpus()
        for scenario in corpus.scenarios {
            assertScenarioMatches(scenario, replay: try replay(scenario))
        }
    }

    /// Also drives the production solver fast path (1×1 grid per active
    /// condition) so corpus parity covers the selection code the app
    /// actually runs, not just the scorer in isolation.
    func testSolverFastPathSelectionMatchesCorpus() throws {
        let corpus = try loadCorpus()
        let solver = CompositionSolver()
        var replayed = 0

        for scenario in corpus.scenarios {
            let weights = makeWeights(scenario.weights)
            var grids: [LightingCondition: BrightnessGrid] = [:]
            var targetComplete = true
            for (condition, _) in weights.activeEntries {
                guard let value = scenario.target.channels[condition.rawValue] else {
                    targetComplete = false
                    break
                }
                grids[condition] = BrightnessGrid(width: 1, height: 1, fill: value)
            }

            // Source grids always supply a value for every active condition, so
            // a target-side missing channel only exists at the scorer layer
            // (covered above); the solver replays complete-target scenarios.
            if !targetComplete {
                XCTAssertNil(scenario.expected.selectedIndex, "[\(scenario.id)] must expect no selection")
                continue
            }

            let palette = try scenario.palette.map(makeColor)
            let result = try solver.solve(palette: palette, sourceGrids: grids, weights: weights)

            XCTAssertEqual(
                result.colorIndex(x: 0, y: 0),
                scenario.expected.selectedIndex,
                "[\(scenario.id)] solver selection"
            )
            if let expectedError = scenario.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, "[\(scenario.id)] solver error")
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, "[\(scenario.id)] unmatched cell error")
            }
            XCTAssertEqual(
                result.excludedCandidateCount,
                scenario.expected.scores.filter { $0.outcome == .excluded }.count,
                "[\(scenario.id)] excluded candidate count"
            )
            replayed += 1
        }
        XCTAssertGreaterThan(replayed, 0, "no scenarios replayed through the solver")
    }

    // MARK: - Tie-breaking

    func testTieScenariosSelectEarliestTiedIndex() throws {
        let corpus = try loadCorpus()
        let tieScenarios = corpus.scenarios.filter { $0.expected.tieBroke == true }
        XCTAssertGreaterThanOrEqual(
            tieScenarios.count,
            3,
            "corpus must include tie cases; found \(tieScenarios.map(\.id))"
        )

        for scenario in tieScenarios {
            let replay = try replay(scenario)
            XCTAssertEqual(replay.tieBroke, true, "[\(scenario.id)]")
            XCTAssertEqual(
                replay.selectedIndex,
                replay.tiedIndices.first,
                "[\(scenario.id)] earliest tied index must win"
            )
            XCTAssertGreaterThan(replay.tiedIndices.count, 1, "[\(scenario.id)] tie needs at least two candidates")
            XCTAssertEqual(replay.tiedIndices, scenario.expected.tiedIndices, "[\(scenario.id)]")
        }
    }

    // MARK: - Missing-measurement exclusion

    func testMissingMeasurementsExcludeRatherThanCountAsZero() throws {
        let corpus = try loadCorpus()
        for id in ["missing-candidate-excluded", "missing-target-excluded", "all-excluded"] {
            let scenario = try scenario(id, in: corpus)
            let replay = try replay(scenario)

            for expectedScore in scenario.expected.scores where expectedScore.outcome == .excluded {
                XCTAssertEqual(
                    replay.scores[expectedScore.index],
                    .excluded,
                    "[\(id)] candidate \(expectedScore.index) must be excluded"
                )
            }
            XCTAssertNil(replay.selectedIndex, "[\(id)] no candidate may be selected")
            XCTAssertNil(replay.bestScore, "[\(id)] no best score may exist")
            XCTAssertNil(replay.tieBroke, "[\(id)] no tie evidence may exist")
            XCTAssertEqual(replay.tiedIndices, [], "[\(id)]")
        }

        // The candidate that matches every measured channel but lacks a
        // positive-weight one loses to the fully-measured runner-up: missing
        // must exclude, never score as zero brightness.
        let scenario = try scenario("missing-candidate-excluded", in: corpus)
        let replay = try replay(scenario)
        XCTAssertEqual(replay.scores[0], .excluded)
        XCTAssertEqual(replay.selectedIndex, 1)
    }

    // MARK: - Weight handling

    func testZeroWeightChannelsNeitherExcludeNorContribute() throws {
        let corpus = try loadCorpus()
        let scenario = try scenario("zero-weight-channel-missing", in: corpus)
        let replay = try replay(scenario)

        guard case .score(let score) = replay.scores[0] else {
            return XCTFail("candidate missing only a zero-weight channel must not be excluded")
        }
        XCTAssertEqual(score, 0.0625, "score must come from the weighted channel alone")
        XCTAssertEqual(replay.selectedIndex, 0, "tied with candidate 1; earliest wins")
        XCTAssertEqual(replay.tiedIndices, [0, 1])
    }

    func testUnknownLightSourceWeightsAreIgnored() throws {
        let corpus = try loadCorpus()
        let scenario = try scenario("unknown-weight-ignored", in: corpus)
        XCTAssertTrue(scenario.weights.keys.contains("ultraviolet"), "scenario must carry an unknown weight key")
        XCTAssertNil(LightingCondition(rawValue: "ultraviolet"), "client must not know ultraviolet")

        let replay = try replay(scenario)
        let baseline = try replay(try scenario("distinct-errors", in: corpus))
        XCTAssertEqual(replay.selectedIndex, baseline.selectedIndex)
        XCTAssertEqual(replay.tiedIndices, baseline.tiedIndices)
        for (actual, expected) in zip(replay.scores, baseline.scores) {
            XCTAssertEqual(actual, expected)
        }
    }

    // MARK: - Per-scenario assertions

    private func assertScenarioMatches(
        _ scenario: Scenario,
        replay: Replay,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = scenario.expected
        let prefix = "[\(scenario.id)] "

        XCTAssertEqual(
            replay.scores.count,
            expected.scores.count,
            prefix + "candidate count",
            file: file,
            line: line
        )

        for expectedScore in expected.scores {
            guard replay.scores.indices.contains(expectedScore.index) else {
                XCTFail(prefix + "expected score for out-of-range index \(expectedScore.index)", file: file, line: line)
                continue
            }
            let actual = replay.scores[expectedScore.index]
            switch expectedScore.outcome {
            case .excluded:
                XCTAssertEqual(actual, .excluded, prefix + "candidate \(expectedScore.index)", file: file, line: line)
            case .score(let value):
                XCTAssertEqual(actual, .score(value), prefix + "candidate \(expectedScore.index) score", file: file, line: line)
            }
        }

        XCTAssertEqual(replay.selectedIndex, expected.selectedIndex, prefix + "selected index", file: file, line: line)
        XCTAssertEqual(replay.tieBroke, expected.tieBroke, prefix + "tie_broke", file: file, line: line)
        XCTAssertEqual(replay.tiedIndices, expected.tiedIndices, prefix + "tied indices", file: file, line: line)

        if let expectedError = expected.error {
            XCTAssertEqual(replay.bestScore, expectedError, prefix + "winning error", file: file, line: line)
        } else {
            XCTAssertNil(replay.bestScore, prefix + "no winner means no error", file: file, line: line)
        }

        if let selected = replay.selectedIndex {
            XCTAssertEqual(
                scenario.palette[selected].hexColor,
                expected.selectedHexColor,
                prefix + "selected hex color",
                file: file,
                line: line
            )
        } else {
            XCTAssertNil(expected.selectedHexColor, prefix + "no selection means no hex", file: file, line: line)
        }
    }
}
