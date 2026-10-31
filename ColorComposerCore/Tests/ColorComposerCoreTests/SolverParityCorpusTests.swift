import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the committed `color_matching` solver parity corpus through
/// `WeightedSquaredErrorScorer` and `CompositionSolver` and asserts exact
/// agreement with the server-recorded expectations.
///
/// The corpus is the golden-vector fixture produced by the Elixir service
/// (viamin/color_matching#111, landed as #112) and vendored byte-identical at
/// `Fixtures/parity/v1/corpus.json`. Every scenario carries the palette
/// response vectors, the target vector, the channel weights, the
/// per-candidate score table (`"excluded"` marks missing-measurement
/// exclusions), the expected selection and error, and explicit tie-break
/// evidence (`tie_broke`, `tied_indices`) — with ties intentionally included.
///
/// Any mismatch here means this app has diverged from the server on
/// tie-breaking (earliest index wins), missing-measurement exclusion (never
/// treated as zero brightness), or channel weighting. See
/// `docs/solver-parity-corpus.md` for the refresh procedure.
///
/// `algorithm_version` couples the corpus to the scorer semantics: when the
/// stamp changes, every expectation has moved and both the fixture and any
/// semantic assumptions must be updated in step.
///
/// Lives in the `ColorComposerCoreTests` target; splitting into a dedicated
/// parity target is possible later but would only repeat this wiring.
final class SolverParityCorpusTests: XCTestCase {
    // MARK: - Corpus wire format

    private struct Corpus: Codable {
        let algorithmVersion: Int
        let scorer: String
        let selection: String
        let missingPolicy: String
        let lightSources: [String]
        let scenarios: [Scenario]
    }

    private struct Scenario: Codable {
        let id: String
        let description: String
        let weights: [String: Double]
        let target: VectorEntry
        let palette: [VectorEntry]
        let expected: Expected
    }

    private struct VectorEntry: Codable {
        let index: Int?
        let hexColor: String
        let channels: [String: Double]
    }

    private struct Expected: Codable {
        let scores: [ScoreEntry]
        let selectedIndex: Int?
        let selectedHexColor: String?
        let error: Double?
        let tieBroke: Bool?
        let tiedIndices: [Int]
    }

    private struct ScoreEntry: Codable {
        let index: Int
        let score: ParityScore
    }

    /// One recorded server outcome: `"excluded"` or a finite weighted error.
    private enum ParityScore: Codable, Equatable {
        case excluded
        case score(Double)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                self = .score(value)
            } else if let marker = try? container.decode(String.self), marker == "excluded" {
                self = .excluded
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: #"score must be a number or "excluded""#
                )
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

    // MARK: - Fixture loading

    /// Resolved from `#filePath` (not `Bundle.module`) so the fixture loads
    /// under plain `swift test` without declaring package resources.
    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/parity/v1/corpus.json")

    private func loadCorpus(file: StaticString = #filePath, line: UInt = #line) throws -> Corpus {
        let data: Data
        do {
            data = try Data(contentsOf: Self.fixtureURL)
        } catch {
            XCTFail("parity corpus fixture is missing at \(Self.fixtureURL.path): \(error)", file: file, line: line)
            throw error
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Corpus.self, from: data)
        } catch {
            XCTFail("parity corpus fixture failed to decode: \(error)", file: file, line: line)
            throw error
        }
    }

    // MARK: - Corpus → domain conversion

    /// Channel weights for a scenario. Weight keys outside the five canonical
    /// light sources (the corpus carries an `ultraviolet` key in one scenario)
    /// are ignored, matching `ChannelWeights`' fixed channel set.
    private func makeWeights(_ map: [String: Double]) -> ChannelWeights {
        func value(_ condition: LightingCondition) -> Double { map[condition.rawValue] ?? 0 }
        return ChannelWeights(
            white: value(.white),
            red: value(.red),
            green: value(.green),
            blue: value(.blue),
            lps: value(.lps)
        )
    }

    /// A corpus palette entry as a solver-ready color. Present channels become
    /// measurements; absent channels stay absent so "missing" remains
    /// distinguishable from "measured as zero".
    private func makeColor(from entry: VectorEntry, id: Int) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: entry.hexColor), "corpus hex unparseable: \(entry.hexColor)")
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, value) in entry.channels {
            if let condition = LightingCondition(rawValue: key) {
                responses[condition] = IlluminationResponse(brightness: value)
            }
        }
        return PaletteColor(id: id, hex: entry.hexColor, rgb: rgb, responses: responses)
    }

    private func makePalette(for scenario: Scenario) throws -> [PaletteColor] {
        var palette: [PaletteColor] = []
        for (offset, entry) in scenario.palette.enumerated() {
            palette.append(try makeColor(from: entry, id: offset))
        }
        return palette
    }

    private func makeTarget(for scenario: Scenario) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in scenario.target.channels {
            if let condition = LightingCondition(rawValue: key) {
                brightness[condition] = value
            }
        }
        return TargetResponseVector(brightness)
    }

    /// One recorded outcome of replaying a scenario with the default scorer.
    private struct Replay {
        let scores: [ParityScore]
        let selectedIndex: Int?
        let selectedScore: Double?
        let tiedIndices: [Int]
    }

    /// Scores every candidate exactly as `IlluminantMatching.score_candidates`
    /// would, then selects the lowest score with earliest-index tie-breaking,
    /// exactly as `IlluminantMatching.best_match` and
    /// `CompositionSolver.bestCandidate` do.
    private func replay(_ scenario: Scenario) throws -> Replay {
        let scorer = WeightedSquaredErrorScorer()
        let weights = makeWeights(scenario.weights)
        let target = makeTarget(for: scenario)
        let palette = try makePalette(for: scenario)

        var scores: [ParityScore] = []
        var bestIndex: Int?
        var bestScore = Double.infinity
        for (index, candidate) in palette.enumerated() {
            switch scorer.score(candidate: candidate, target: target, weights: weights) {
            case .excluded:
                scores.append(.excluded)
            case .score(let score):
                scores.append(.score(score))
                if score < bestScore {
                    bestScore = score
                    bestIndex = index
                }
            }
        }

        let tiedIndices = (0..<scores.count).filter {
            guard case .score(let value) = scores[$0] else { return false }
            return value == bestScore
        }
        return Replay(
            scores: scores,
            selectedIndex: bestIndex,
            selectedScore: bestIndex == nil ? nil : bestScore,
            tiedIndices: bestIndex == nil ? [] : tiedIndices
        )
    }

    // MARK: - Envelope contract

    /// The corpus must declare the semantics this replay assumes; a change in
    /// any stamp (especially `algorithm_version`) means every recorded
    /// expectation moved and this suite must be revisited in step.
    func testCorpusEnvelopeMatchesDocumentedContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1, "algorithm_version moved; every expectation changed")
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(
            Set(corpus.lightSources),
            Set(LightingCondition.allCases.map(\.rawValue)),
            "corpus light sources must be exactly the canonical channel set"
        )
        XCTAssertGreaterThanOrEqual(corpus.scenarios.count, 10, "corpus unexpectedly small")

        // The corpus must keep exercising the interesting semantics, or the
        // fixture has degraded into trivially-passing cases.
        XCTAssertTrue(
            corpus.scenarios.contains { $0.expected.tieBroke == true },
            "corpus no longer contains tie-break evidence"
        )
        XCTAssertTrue(
            corpus.scenarios.contains { scenario in scenario.expected.scores.contains { $0.score == .excluded } },
            "corpus no longer contains missing-measurement exclusions"
        )
        XCTAssertTrue(
            corpus.scenarios.contains { $0.expected.selectedIndex == nil },
            "corpus no longer contains an all-excluded scenario"
        )
    }

    /// Internal fixture integrity: palette entries and the score table are
    /// index-addressed, so positions must line up before any comparison.
    func testCorpusIndicesArePositional() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            let positionalIndices = scenario.palette.indices.map { Optional($0) }
            XCTAssertEqual(
                scenario.palette.map(\.index),
                positionalIndices,
                "scenario \(scenario.id): palette index stamps must be positional"
            )
            XCTAssertEqual(
                scenario.expected.scores.map(\.index),
                Array(scenario.palette.indices),
                "scenario \(scenario.id): score table must cover the palette in order"
            )
            if let selected = scenario.expected.selectedIndex {
                XCTAssertNotNil(scenario.expected.tieBroke, "scenario \(scenario.id)")
                XCTAssertNotNil(scenario.expected.error, "scenario \(scenario.id)")
                XCTAssertNotNil(scenario.expected.selectedHexColor, "scenario \(scenario.id)")
                XCTAssertTrue(scenario.expected.tiedIndices.contains(selected), "scenario \(scenario.id)")
            } else {
                XCTAssertNil(scenario.expected.tieBroke, "scenario \(scenario.id)")
                XCTAssertNil(scenario.expected.error, "scenario \(scenario.id)")
                XCTAssertNil(scenario.expected.selectedHexColor, "scenario \(scenario.id)")
                XCTAssertTrue(scenario.expected.tiedIndices.isEmpty, "scenario \(scenario.id)")
            }
        }
    }

    // MARK: - Parity

    /// Per-candidate score tables must match the server's exactly: numeric
    /// scores agree within float noise, and `"excluded"` marks the same
    /// candidates — a missing measurement on a positive-weight channel is
    /// excluded, never treated as zero brightness.
    func testScoreTablesMatchCorpusExactly() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            let replay = try replay(scenario)

            XCTAssertEqual(replay.scores.count, scenario.expected.scores.count, "scenario \(scenario.id)")
            for (position, pair) in zip(replay.scores, scenario.expected.scores).enumerated() {
                switch (pair.0, pair.1.score) {
                case (.excluded, .excluded):
                    continue
                case (.score(let actual), .score(let expected)):
                    XCTAssertEqual(
                        actual, expected, accuracy: 1e-12,
                        "scenario \(scenario.id): candidate \(position) scored \(actual), server recorded \(expected)"
                    )
                case let (actual, expected):
                    XCTFail(
                        "scenario \(scenario.id): candidate \(position) exclusion mismatch — local \(actual), server \(expected)"
                    )
                }
            }
        }
    }

    /// Selections, errors, and tie evidence must match exactly — including
    /// the tie scenarios, where the earliest tied index must win.
    func testSelectionsMatchCorpusIncludingTieBreaks() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            let replay = try replay(scenario)
            let expected = scenario.expected

            XCTAssertEqual(
                replay.selectedIndex, expected.selectedIndex,
                "scenario \(scenario.id): selected index diverged"
            )
            XCTAssertEqual(
                replay.tiedIndices, expected.tiedIndices,
                "scenario \(scenario.id): tied index set diverged"
            )
            XCTAssertEqual(
                replay.tiedIndices.count > 1, expected.tieBroke == true,
                "scenario \(scenario.id): tie_broke evidence diverged"
            )

            guard let selectedIndex = expected.selectedIndex else {
                XCTAssertNil(replay.selectedScore, "scenario \(scenario.id)")
                continue
            }
            guard scenario.palette.indices.contains(selectedIndex) else {
                XCTFail("scenario \(scenario.id): selected index \(selectedIndex) outside the palette")
                continue
            }

            XCTAssertEqual(
                scenario.palette[selectedIndex].hexColor, expected.selectedHexColor,
                "scenario \(scenario.id): selected hex diverged"
            )
            if let localScore = replay.selectedScore, let serverError = expected.error {
                XCTAssertEqual(
                    localScore, serverError, accuracy: 1e-12,
                    "scenario \(scenario.id): selected error diverged"
                )
            } else {
                XCTFail("scenario \(scenario.id): selection must record a score and an error")
            }
        }
    }

    /// The corpus's `unknown-weight-ignored` scenario weights an unknown light
    /// source (`ultraviolet`); the fixed channel set must ignore it and land
    /// on the same selection and error as its unmodified twin scenario.
    func testUnknownChannelWeightsAreIgnored() throws {
        let corpus = try loadCorpus()
        let scenarios = Dictionary(uniqueKeysWithValues: corpus.scenarios.map { ($0.id, $0) })

        let unknownWeight = try XCTUnwrap(scenarios["unknown-weight-ignored"], "scenario missing from corpus")
        let baseline = try XCTUnwrap(scenarios["distinct-errors"], "scenario missing from corpus")

        XCTAssertTrue(unknownWeight.weights.keys.contains("ultraviolet"))
        XCTAssertEqual(
            Set(unknownWeight.weights.keys).subtracting(baseline.weights.keys),
            Set(["ultraviolet"]),
            "the unknown-weight scenario must differ from its baseline by exactly the unknown key"
        )

        let weights = makeWeights(unknownWeight.weights)
        XCTAssertEqual(weights.activeConditions.count, 5, "unknown keys must not activate a channel")

        let replayed = try replay(unknownWeight)
        XCTAssertEqual(replayed.selectedIndex, baseline.expected.selectedIndex)
        XCTAssertEqual(replayed.selectedScore ?? -1, baseline.expected.error ?? -2, accuracy: 1e-12)
    }

    /// The scorer-level replay must also hold through `CompositionSolver`'s
    /// optimized contiguous fast path (its own implementation), by solving a
    /// 1×1 composition per scenario.
    ///
    /// The one scenario whose *target* is missing a positive-weight channel
    /// has no grid representation — brightness grids carry measured values
    /// only — and stays covered by the scorer-level replay above.
    func testSolverFastPathMatchesCorpusSelection() throws {
        let corpus = try loadCorpus()
        let solver = CompositionSolver()
        var replayedScenarios = 0

        for scenario in corpus.scenarios {
            let weights = makeWeights(scenario.weights)
            let active = weights.activeConditions
            guard active.allSatisfy({ scenario.target.channels[$0.rawValue] != nil }) else { continue }

            var grids: [LightingCondition: BrightnessGrid] = [:]
            for condition in active {
                grids[condition] = BrightnessGrid(
                    width: 1,
                    height: 1,
                    values: [scenario.target.channels[condition.rawValue]!]
                )
            }

            let result = try solver.solve(
                palette: makePalette(for: scenario),
                sourceGrids: grids,
                weights: weights
            )
            replayedScenarios += 1

            if let expectedIndex = scenario.expected.selectedIndex {
                XCTAssertEqual(result.colorIndex(x: 0, y: 0), Optional(expectedIndex), "scenario \(scenario.id)")
                XCTAssertEqual(
                    result.error(x: 0, y: 0), scenario.expected.error ?? -1, accuracy: 1e-12,
                    "scenario \(scenario.id)"
                )
            } else {
                XCTAssertNil(result.colorIndex(x: 0, y: 0), "scenario \(scenario.id)")
                XCTAssertEqual(result.error(x: 0, y: 0), Double.infinity, "scenario \(scenario.id)")
            }
        }

        XCTAssertGreaterThan(replayedScenarios, 0, "no scenario was expressible as a grid replay")
    }
}
