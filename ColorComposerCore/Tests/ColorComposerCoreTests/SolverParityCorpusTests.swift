import Foundation
import XCTest
@testable import ColorComposerCore

/// Solver parity against the committed `color_matching` corpus.
///
/// `WeightedSquaredErrorScorer` deliberately mirrors the Elixir
/// `ColorMatching.WeightedSquaredError` solver, and the earliest-wins
/// selection mirrors `IlluminantMatching.best_match/4` inside
/// `CompositionSolver`. This suite replays the golden-vector corpus committed
/// from viamin/color_matching (`Fixtures/parity/v1/corpus.json`; see
/// docs/solver-parity-corpus.md for how to refresh it) so tie-breaking,
/// missing-measurement exclusion, and channel weighting cannot silently
/// diverge between client and server.
///
/// Every corpus value is an exact dyadic rational (`k / 2^n`), so the
/// per-channel arithmetic is exact in IEEE doubles and the expected scores
/// compare without ordering-dependent rounding.
final class SolverParityCorpusTests: XCTestCase {
    /// Scoring/selection semantics captured by the committed fixture. Bump
    /// this (and refresh the fixture) when the server bumps its
    /// `algorithm_version`.
    private static let supportedAlgorithmVersion = 1

    /// The fixture is loaded by path (SwiftPM does not copy undeclared files
    /// into the bundle), relative to this source file.
    private static let corpusURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/parity/v1/corpus.json")

    private var corpus: ParityCorpus!

    override func setUpWithError() throws {
        let data = try Data(contentsOf: Self.corpusURL)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        corpus = try decoder.decode(ParityCorpus.self, from: data)
    }

    // MARK: - Corpus metadata

    func testCorpusTracksWeightedSquaredErrorWithEarliestIndexWins() {
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.algorithmVersion, Self.supportedAlgorithmVersion)
    }

    func testCorpusLightSourcesMatchClientConditions() {
        XCTAssertEqual(Set(corpus.lightSources), Set(LightingCondition.allCases.map(\.rawValue)))
    }

    func testCorpusScenarioIdsAreUniqueAndScoreEveryCandidate() {
        XCTAssertGreaterThanOrEqual(corpus.scenarios.count, 12)
        XCTAssertEqual(Set(corpus.scenarios.map(\.id)).count, corpus.scenarios.count)

        for scenario in corpus.scenarios {
            XCTAssertEqual(
                scenario.expected.scores.count,
                scenario.palette.count,
                "\(scenario.id): every candidate must carry an expected score"
            )
            for (position, vector) in scenario.palette.enumerated() where vector.index != position {
                XCTFail("\(scenario.id): palette entry \(position) has index \(String(describing: vector.index))")
            }
            for (position, indexed) in scenario.expected.scores.enumerated() where indexed.index != position {
                XCTFail("\(scenario.id): expected score \(position) has index \(indexed.index)")
            }
        }
    }

    /// Guards the fixture against a refresh that would silently drop the
    /// behavior classes this client depends on: exact ties, exclusion that
    /// still leaves a measurable winner, unmatchable targets, and unknown
    /// light-source weight keys.
    func testCorpusCoversTiesExclusionsAndUnmatchableTargets() {
        XCTAssertTrue(
            corpus.scenarios.contains { $0.expected.tieBroke == true },
            "corpus must keep at least one exact-tie scenario"
        )
        XCTAssertTrue(
            corpus.scenarios.contains { scenario in
                scenario.expected.scores.contains { $0.score == .excluded }
                    && scenario.expected.selectedIndex != nil
            },
            "corpus must keep a scenario where an excluded candidate loses to a measurable winner"
        )
        XCTAssertTrue(
            corpus.scenarios.contains { $0.expected.selectedIndex == nil },
            "corpus must keep a scenario where no candidate is selectable"
        )
        XCTAssertTrue(
            corpus.scenarios.contains { scenario in
                scenario.weights.keys.contains { LightingCondition(rawValue: $0) == nil }
            },
            "corpus must keep a scenario with an unknown light-source weight key"
        )
    }

    // MARK: - Scorer replay

    /// Every scenario must reproduce its expected per-candidate scores,
    /// selection (including tie-breaking), and winner error exactly.
    func testScorerSelectionsMatchCorpusExactly() throws {
        for scenario in corpus.scenarios {
            let replay = try replayScenario(scenario)
            let expected = scenario.expected
            let label = "\(scenario.id)"

            XCTAssertEqual(replay.selectedIndex, expected.selectedIndex, "\(label): selected index")
            XCTAssertEqual(replay.selectedHexColor, expected.selectedHexColor, "\(label): selected hex color")
            XCTAssertEqual(replay.tiedIndices, expected.tiedIndices, "\(label): tied indices")
            XCTAssertEqual(replay.tieBroke, expected.tieBroke, "\(label): tie_broke")

            if let expectedError = expected.error {
                guard let replayError = replay.error else {
                    return XCTFail("\(label): expected a winner error of \(expectedError)")
                }
                XCTAssertEqual(replayError, expectedError, accuracy: 1e-12, "\(label): winner error")
            } else {
                XCTAssertNil(replay.error, "\(label): expected no winner")
            }

            for indexed in expected.scores {
                guard indexed.index >= 0, indexed.index < replay.scores.count else {
                    return XCTFail("\(label): expected score index \(indexed.index) out of range")
                }
                switch (replay.scores[indexed.index], indexed.score) {
                case (.excluded, .excluded):
                    continue
                case (.score(let actual), .score(let expectedScore)):
                    XCTAssertEqual(
                        actual, expectedScore, accuracy: 1e-12,
                        "\(label): candidate \(indexed.index) score"
                    )
                case let (actual, expectedScore):
                    XCTFail("\(label): candidate \(indexed.index) scored \(actual), expected \(expectedScore)")
                }
            }
        }
    }

    // MARK: - Solver replay (end-to-end fast path)

    /// `CompositionSolver`'s optimized contiguous fast path re-implements the
    /// scoring loop, so scenarios whose target covers every positive-weight
    /// channel are also replayed through a real 1x1 solve. A target missing a
    /// positive-weight channel models "no source image assigned" in the app
    /// and never reaches the solver, so those scenarios replay through the
    /// scorer only.
    func testSolverFastPathSelectionsMatchCorpus() throws {
        var replayed = 0

        for scenario in corpus.scenarios {
            let weights = Self.weights(from: scenario.weights)
            let activeChannels = weights.activeEntries.map(\.condition)
            let replayable = activeChannels.allSatisfy { channel in
                scenario.target.channels[channel.rawValue] != nil
            }
            guard replayable else { continue }

            let palette = try palette(for: scenario)
            let sourceGrids = Self.sourceGrids(target: scenario.target, activeChannels: activeChannels)
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: sourceGrids,
                weights: weights
            )
            replayed += 1

            let expected = scenario.expected
            XCTAssertEqual(
                result.colorIndex(x: 0, y: 0), expected.selectedIndex,
                "\(scenario.id): solver selection"
            )
            if let expectedError = expected.error {
                XCTAssertEqual(
                    result.error(x: 0, y: 0), expectedError, accuracy: 1e-12,
                    "\(scenario.id): solver error"
                )
            } else {
                XCTAssertTrue(
                    result.error(x: 0, y: 0).isInfinite,
                    "\(scenario.id): unmatched cell must report infinite error"
                )
            }
            XCTAssertEqual(
                result.excludedCandidateCount,
                expected.scores.filter(\.score.isExcluded).count,
                "\(scenario.id): excluded candidate count"
            )
        }

        XCTAssertGreaterThanOrEqual(
            replayed, 8,
            "most corpus scenarios should exercise the solver end-to-end"
        )
    }

    // MARK: - Replay helpers

    private struct ReplayOutcome {
        let selectedIndex: Int?
        let selectedHexColor: String?
        let tiedIndices: [Int]
        let tieBroke: Bool?
        let error: Double?
        let scores: [ParityScore]
    }

    /// Scores every candidate with `WeightedSquaredErrorScorer` and applies
    /// earliest-index-wins selection, mirroring the corpus `selection`
    /// policy.
    private func replayScenario(_ scenario: ParityScenario) throws -> ReplayOutcome {
        let palette = try palette(for: scenario)
        let target = Self.targetVector(from: scenario.target)
        let weights = Self.weights(from: scenario.weights)

        let scorer = WeightedSquaredErrorScorer()
        var scores: [ParityScore] = []
        for color in palette {
            switch scorer.score(candidate: color, target: target, weights: weights) {
            case .score(let value): scores.append(.score(value))
            case .excluded: scores.append(.excluded)
            }
        }

        var selectedIndex: Int?
        var bestScore = Double.infinity
        for (index, outcome) in scores.enumerated() {
            guard case .score(let value) = outcome else { continue }
            if value < bestScore { // strict `<` keeps the earliest index on ties
                bestScore = value
                selectedIndex = index
            }
        }

        var tiedIndices: [Int] = []
        for (index, outcome) in scores.enumerated() {
            guard case .score(let value) = outcome, selectedIndex != nil, value == bestScore else { continue }
            tiedIndices.append(index)
        }

        return ReplayOutcome(
            selectedIndex: selectedIndex,
            selectedHexColor: selectedIndex.map { palette[$0].hex },
            tiedIndices: tiedIndices,
            tieBroke: selectedIndex == nil ? nil : tiedIndices.count > 1,
            error: selectedIndex == nil ? nil : bestScore,
            scores: scores
        )
    }

    private func palette(for scenario: ParityScenario) throws -> [PaletteColor] {
        try scenario.palette.map { vector in
            let hex = try XCTUnwrap(vector.hexColor, "corpus vectors must carry hex_color")
            let rgb = try XCTUnwrap(RGBColor(hex: hex), "corpus hex must parse: \(hex)")
            return PaletteColor(
                id: vector.index ?? -1,
                hex: hex,
                rgb: rgb,
                responses: Self.responses(from: vector.channels)
            )
        }
    }

    private static func responses(
        from channels: [String: Double]
    ) -> [LightingCondition: IlluminationResponse] {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, value) in channels {
            if let condition = LightingCondition(rawValue: key) {
                responses[condition] = IlluminationResponse(brightness: value)
            }
        }
        return responses
    }

    private static func targetVector(
        from vector: ParityVector
    ) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in vector.channels {
            if let condition = LightingCondition(rawValue: key) {
                brightness[condition] = value
            }
        }
        return TargetResponseVector(brightness)
    }

    /// Unknown light-source keys (e.g. `ultraviolet`) are dropped, mirroring
    /// the server's `filter_weights/1` and the client's DTO conversion.
    private static func weights(from raw: [String: Double]) -> ChannelWeights {
        var weights = ChannelWeights()
        for (key, value) in raw {
            switch LightingCondition(rawValue: key) {
            case .white: weights.white = value
            case .red: weights.red = value
            case .green: weights.green = value
            case .blue: weights.blue = value
            case .lps: weights.lps = value
            case nil: break
            }
        }
        return weights
    }

    private static func sourceGrids(
        target: ParityVector,
        activeChannels: [LightingCondition]
    ) -> [LightingCondition: BrightnessGrid] {
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for channel in activeChannels {
            grids[channel] = BrightnessGrid(
                width: 1,
                height: 1,
                values: [target.channels[channel.rawValue] ?? 0]
            )
        }
        return grids
    }
}

// MARK: - Corpus wire model

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let description: String?
    let weights: [String: Double]
    let target: ParityVector
    let palette: [ParityVector]
    let expected: ParityExpectation
}

private struct ParityVector: Decodable {
    let hexColor: String?
    let index: Int?
    let channels: [String: Double]
}

private struct ParityExpectation: Decodable {
    struct IndexedScore: Decodable {
        let index: Int
        let score: ParityScore
    }

    let selectedIndex: Int?
    let selectedHexColor: String?
    let tieBroke: Bool?
    let tiedIndices: [Int]
    let error: Double?
    let scores: [IndexedScore]
}

/// A per-candidate outcome: a finite score, or the string marker
/// `"excluded"`.
private enum ParityScore: Decodable, Equatable {
    case score(Double)
    case excluded

    var isExcluded: Bool {
        if case .excluded = self { return true }
        return false
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let marker = try? container.decode(String.self), marker == "excluded" {
            self = .excluded
        } else {
            self = .score(try container.decode(Double.self))
        }
    }
}
