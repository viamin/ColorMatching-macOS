import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the solver-parity golden-vector corpus published by the
/// `color_matching` server (viamin/color_matching#112) against this package's
/// `WeightedSquaredErrorScorer` and `CompositionSolver`.
///
/// The corpus is the shared contract that keeps the macOS client and the
/// Elixir server selecting identical colors: per-candidate weighted squared
/// errors, missing-measurement exclusions, and earliest-index-wins
/// tie-breaking. Any divergence — including tie cases — fails here.
///
/// Refresh the committed copy from the server repo (see
/// docs/solver-parity-corpus.md):
///
///     curl -o .../Fixtures/ParityCorpus/v1/corpus.json \
///       https://raw.githubusercontent.com/viamin/color_matching/main/priv/parity/v1/corpus.json
final class SolverParityCorpusTests: XCTestCase {

    // MARK: - Corpus integrity

    /// The corpus describes the exact contract this client implements; verify
    /// its self-description before trusting any scenario inside it.
    func testCorpusMetadataMatchesClientContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1, "Corpus algorithm version advanced; re-verify parity and update this test deliberately")
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        // The server's light-source vocabulary must be exactly the client's.
        XCTAssertEqual(corpus.lightSources, LightingCondition.allCases.map(\.rawValue))

        let ids = corpus.scenarios.map(\.id)
        XCTAssertEqual(ids.count, 12, "Scenario set changed upstream; review the diff before updating the fixture")
        XCTAssertEqual(Set(ids).count, ids.count, "Scenario ids must be unique")

        // The corpus deliberately covers tie-breaking; keep it that way.
        let tieScenarios = corpus.scenarios.filter { $0.expected.tieBroke == true }
        XCTAssertGreaterThanOrEqual(tieScenarios.count, 3, "Corpus lost its tie-break coverage")
        XCTAssertLessThan(tieScenarios.count, corpus.scenarios.count, "Corpus should also contain non-tie scenarios")
    }

    // MARK: - Scorer parity

    /// Every per-candidate score and exclusion in the corpus must be
    /// reproduced exactly by `WeightedSquaredErrorScorer`.
    func testScorerReproducesPerCandidateScoresAndExclusions() throws {
        let corpus = try loadCorpus()
        XCTAssertFalse(corpus.scenarios.isEmpty)

        for scenario in corpus.scenarios {
            let palette = try makePalette(scenario)
            let target = try makeTarget(scenario)
            let weights = makeWeights(scenario)

            XCTAssertEqual(
                scenario.expected.scores.map(\.index),
                Array(palette.indices),
                "\(scenario.id): expected.scores must cover every palette index in order"
            )

            let scorer = WeightedSquaredErrorScorer()
            for expectedScore in scenario.expected.scores {
                let candidate = palette[expectedScore.index]
                let actual = scorer.score(candidate: candidate, target: target, weights: weights)

                switch (expectedScore.score, actual) {
                case let (.score(expectedValue), .score(actualValue)):
                    XCTAssertEqual(
                        actualValue, expectedValue, accuracy: 1e-12,
                        "\(scenario.id): candidate \(expectedScore.index) score mismatch"
                    )
                case (.excluded, .excluded):
                    break
                default:
                    XCTFail(
                        "\(scenario.id): candidate \(expectedScore.index) expected \(expectedScore.score) but got \(actual)"
                    )
                }
            }
        }
    }

    /// Selection must match the corpus exactly — including ties, where the
    /// earliest index among equally-scoped candidates wins.
    func testEarliestIndexWinsSelectionMatchesCorpus() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            let palette = try makePalette(scenario)
            let target = try makeTarget(scenario)
            let weights = makeWeights(scenario)

            let replayed = replaySelection(palette: palette, target: target, weights: weights)

            XCTAssertEqual(
                replayed.selectedIndex, scenario.expected.selectedIndex,
                "\(scenario.id): selected index mismatch"
            )

            if let selectedIndex = replayed.selectedIndex {
                let selectedColor = palette[selectedIndex]
                XCTAssertEqual(
                    selectedColor.hex, scenario.expected.selectedHexColor,
                    "\(scenario.id): selected color hex mismatch"
                )
                if let expectedError = scenario.expected.error {
                    XCTAssertEqual(
                        replayed.bestScore ?? .infinity, expectedError, accuracy: 1e-12,
                        "\(scenario.id): winning error mismatch"
                    )
                }
            } else {
                XCTAssertNil(scenario.expected.error, "\(scenario.id): expected an error with no selection")
                XCTAssertNil(scenario.expected.selectedHexColor, "\(scenario.id): expected a hex with no selection")
            }

            XCTAssertEqual(
                replayed.tiedIndices, scenario.expected.tiedIndices,
                "\(scenario.id): tied index set mismatch"
            )
            XCTAssertEqual(
                replayed.tieBroke, scenario.expected.tieBroke ?? false,
                "\(scenario.id): tie_broke flag mismatch"
            )
        }
    }

    /// The production `CompositionSolver` fast path (used for every real
    /// composition) must land on the same selections as the corpus.
    func testSolverFastPathSelectsCorpusExpectedColors() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            let palette = try makePalette(scenario)
            let weights = makeWeights(scenario)

            // One 1x1 grid per active condition, filled with the scenario's
            // target brightness — the smallest composition that reproduces
            // the corpus target vector.
            var sourceGrids: [LightingCondition: BrightnessGrid] = [:]
            for (condition, _) in weights.activeEntries {
                let raw = try XCTUnwrap(
                    scenario.target.channels[condition.rawValue],
                    "\(scenario.id): target missing active channel \(condition.rawValue)"
                )
                sourceGrids[condition] = BrightnessGrid(width: 1, height: 1, values: [raw])
            }

            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: sourceGrids,
                weights: weights
            )

            let selectedIndex = result.colorIndex(x: 0, y: 0)
            XCTAssertEqual(
                selectedIndex, scenario.expected.selectedIndex,
                "\(scenario.id): solver selection mismatch"
            )

            let expectedExcluded = scenario.expected.scores.filter {
                if case .excluded = $0.score { return true }
                return false
            }.count
            XCTAssertEqual(
                result.excludedCandidateCount, expectedExcluded,
                "\(scenario.id): excluded candidate count mismatch"
            )

            if let expectedError = scenario.expected.error {
                XCTAssertEqual(
                    result.error(x: 0, y: 0), expectedError, accuracy: 1e-12,
                    "\(scenario.id): solver error mismatch"
                )
            } else {
                XCTAssertEqual(
                    result.error(x: 0, y: 0), .infinity,
                    "\(scenario.id): expected no eligible candidate"
                )
            }
        }
    }

    // MARK: - Corpus decoding

    private struct ParityCorpus: Decodable {
        let algorithmVersion: Int
        let lightSources: [String]
        let missingPolicy: String
        let scorer: String
        let selection: String
        let scenarios: [Scenario]
    }

    private struct Scenario: Decodable {
        let id: String
        let description: String
        let palette: [Candidate]
        let target: Target
        let weights: [String: Double]
        let expected: Expectation
    }

    private struct Candidate: Decodable {
        let index: Int
        let hexColor: String
        let channels: [String: Double]
    }

    private struct Target: Decodable {
        let channels: [String: Double]
    }

    private struct Expectation: Decodable {
        struct IndexedScore: Decodable {
            let index: Int
            let score: ExpectedScore
        }

        let scores: [IndexedScore]
        let selectedIndex: Int?
        let selectedHexColor: String?
        let error: Double?
        let tieBroke: Bool?
        let tiedIndices: [Int]
    }

    /// A corpus score is either a number or the symbol `"excluded"`.
    private enum ExpectedScore: Decodable, CustomStringConvertible {
        case score(Double)
        case excluded

        var description: String {
            switch self {
            case .score(let value): return ".score(\(value))"
            case .excluded: return ".excluded"
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                self = .score(value)
                return
            }
            let symbol = try container.decode(String.self)
            guard symbol == "excluded" else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown score symbol: \(symbol)"
                )
            }
            self = .excluded
        }
    }

    // MARK: - Domain mapping

    private func makePalette(_ scenario: Scenario) throws -> [PaletteColor] {
        try scenario.palette.sorted { $0.index < $1.index }.map(makeColor)
    }

    private func makeColor(_ candidate: Candidate) throws -> PaletteColor {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, value) in candidate.channels {
            if let condition = LightingCondition(rawValue: key) {
                responses[condition] = IlluminationResponse(brightness: value)
            }
        }
        let rgb = try XCTUnwrap(RGBColor(hex: candidate.hexColor), "Corpus hex \(candidate.hexColor) is not parseable")
        return PaletteColor(id: candidate.index, hex: candidate.hexColor, rgb: rgb, responses: responses)
    }

    private func makeTarget(_ scenario: Scenario) throws -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in scenario.target.channels {
            if let condition = LightingCondition(rawValue: key) {
                brightness[condition] = value
            }
        }
        return TargetResponseVector(brightness)
    }

    /// Unknown weight keys (e.g. `ultraviolet`) are dropped: only canonical
    /// conditions exist client-side, which the `unknown-weight-ignored`
    /// corpus scenario relies on.
    private func makeWeights(_ scenario: Scenario) -> ChannelWeights {
        func weight(_ condition: LightingCondition) -> Double {
            scenario.weights[condition.rawValue] ?? 0
        }
        return ChannelWeights(
            white: weight(.white),
            red: weight(.red),
            green: weight(.green),
            blue: weight(.blue),
            lps: weight(.lps)
        )
    }

    // MARK: - Selection replay

    private struct SelectionReplay {
        let selectedIndex: Int?
        let bestScore: Double?
        let tiedIndices: [Int]
        let tieBroke: Bool
    }

    /// Replays the documented selection policy independently of the solver:
    /// strictly-lower scores replace the incumbent, so the earliest member of
    /// a tied set wins.
    private func replaySelection(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> SelectionReplay {
        let scorer = WeightedSquaredErrorScorer()
        var scores: [(index: Int, score: Double)] = []

        for (index, candidate) in palette.enumerated() {
            if case .score(let value) = scorer.score(candidate: candidate, target: target, weights: weights) {
                scores.append((index, value))
            }
        }

        guard let best = scores.map(\.score).min() else {
            return SelectionReplay(selectedIndex: nil, bestScore: nil, tiedIndices: [], tieBroke: false)
        }
        let tied = scores.filter { abs($0.score - best) <= 1e-12 }.map(\.index)
        return SelectionReplay(
            selectedIndex: tied.first,
            bestScore: best,
            tiedIndices: tied,
            tieBroke: tied.count > 1
        )
    }

    // MARK: - Fixture loading

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ParityCorpus/v1/corpus.json")

        let data = try Data(contentsOf: fixtureURL)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: data)
    }
}
