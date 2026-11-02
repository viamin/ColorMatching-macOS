import Foundation
import XCTest
@testable import ColorComposerCore

/// Solver parity against the committed golden-vector corpus.
///
/// The corpus (`../Fixtures/ParityCorpus/corpus.json` relative to this file,
/// i.e. `Tests/Fixtures/ParityCorpus/corpus.json`) is a byte-exact copy of
/// `priv/parity/v1/corpus.json` from the `color_matching` server (generated
/// by `mix parity.generate`, PR viamin/color_matching#111). The server's
/// `ColorMatching.WeightedSquaredError` solver and earliest-wins selection
/// are the source of truth; `WeightedSquaredErrorScorer` must reproduce every
/// expected score, exclusion, selection, and tie decision exactly.
///
/// All corpus numbers are exact binary fractions, so every arithmetic
/// operation in between is exact in IEEE 754 `Double` — comparisons are
/// bit-exact (`bitPattern`), not epsilon-based. The fixture lives outside
/// the test target directory and loads via `#filePath`, so it needs no
/// SwiftPM resource declaration. See `docs/parity-corpus.md` for how to
/// refresh the fixture.
final class SolverParityCorpusTests: XCTestCase {
    private static let corpusURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // ColorComposerCoreTests
        .deletingLastPathComponent() // Tests
        .appendingPathComponent("Fixtures/ParityCorpus/corpus.json")

    private static func loadCorpus() throws -> ParityCorpus {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: corpusURL))
    }

    // MARK: - Corpus metadata

    func testCorpusMetadataMatchesSolverSemantics() throws {
        let corpus = try Self.loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1, "algorithm_version bump means every expectation moved; update this test together with the fixture")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.lightSources, LightingCondition.allCases.map(\.rawValue))
    }

    func testCorpusCoversTieAndExclusionScenarios() throws {
        let corpus = try Self.loadCorpus()

        XCTAssertEqual(Set(corpus.scenarios.map(\.id)).count, corpus.scenarios.count, "scenario ids must be unique")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true }, "corpus must cover tie cases")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil }, "corpus must cover no-selection cases")
    }

    // MARK: - Per-candidate scores

    func testPerCandidateScoresMatchExpectedExactly() throws {
        let corpus = try Self.loadCorpus()

        for scenario in corpus.scenarios {
            for expected in scenario.expected.scores {
                let result = scoreCandidate(scenario, index: expected.index)
                switch (result, expected.score) {
                case (.excluded, .excluded):
                    break
                case let (.score(actual), .value(expectedValue)):
                    assertBitExact(actual, expectedValue, "\(scenario.id) candidate \(expected.index)")
                default:
                    XCTFail("\(scenario.id) candidate \(expected.index): expected \(expected.score), got \(result)")
                }
            }
        }
    }

    /// viamin/color_matching#111: an unknown light source in the weights map
    /// (`ultraviolet`) is silently ignored — this scenario's errors must equal
    /// the distinct-errors scenario verbatim.
    func testUnknownWeightSourcesAreIgnored() throws {
        let corpus = try Self.loadCorpus()
        let scores = try scoresByScenarioID(corpus)

        let withUnknown = try XCTUnwrap(scores["unknown-weight-ignored"], "corpus scenario missing")
        let baseline = try XCTUnwrap(scores["distinct-errors"], "corpus scenario missing")

        XCTAssertEqual(withUnknown.count, baseline.count)
        for (unknown, plain) in zip(withUnknown, baseline) {
            XCTAssertEqual(unknown.0, plain.0)
            XCTAssertEqual(unknown.1.bitPattern, plain.1.bitPattern, "unknown light source in weights changed the score")
        }
    }

    // MARK: - Selection (earliest-wins ties)

    func testSelectionMatchesExpectedIncludingTies() throws {
        let corpus = try Self.loadCorpus()

        for scenario in corpus.scenarios {
            guard let selectedIndex = scenario.expected.selectedIndex else { continue }
            let selection = try earliestWinsSelection(scenario)

            XCTAssertEqual(selection.index, selectedIndex, "\(scenario.id): selected index")
            let expectedError = try XCTUnwrap(scenario.expected.error, "\(scenario.id): expected error")
            assertBitExact(selection.error, expectedError, "\(scenario.id): winning error")
            XCTAssertEqual(selection.tiedIndices, scenario.expected.tiedIndices, "\(scenario.id): tied indices")
            XCTAssertEqual(selection.tieBroke, scenario.expected.tieBroke, "\(scenario.id): tie_broke")
            XCTAssertEqual(palette(scenario)[selectedIndex].hexColor, scenario.expected.selectedHexColor, "\(scenario.id): selected hex color")
        }
    }

    func testNoSelectionScenariosExcludeEveryCandidate() throws {
        let corpus = try Self.loadCorpus()

        for scenario in corpus.scenarios where scenario.expected.selectedIndex == nil {
            XCTAssertEqual(scenario.expected.tiedIndices, [], "\(scenario.id)")
            XCTAssertNil(scenario.expected.tieBroke, "\(scenario.id)")

            for (index, color) in palette(scenario).enumerated() {
                XCTAssertEqual(
                    WeightedSquaredErrorScorer().score(candidate: color, target: target(scenario), weights: weights(scenario)),
                    .excluded,
                    "\(scenario.id) candidate \(index) must be excluded when no selection exists"
                )
            }
        }
    }

    /// The corpus's `tied_indices` must be exactly the candidates whose score
    /// equals the winner's — identical bit patterns, not "close enough".
    func testTiedIndicesAreBitExactTies() throws {
        let corpus = try Self.loadCorpus()

        for scenario in corpus.scenarios {
            guard let selectedIndex = scenario.expected.selectedIndex else { continue }
            let winningScore = try XCTUnwrap(scenario.expected.scores.first { $0.index == selectedIndex }?.score.value)

            let tied = scenario.expected.scores.compactMap { entry -> Int? in
                guard case .value(let value) = entry.score, value.bitPattern == winningScore.bitPattern else { return nil }
                return entry.index
            }
            XCTAssertEqual(tied, scenario.expected.tiedIndices, "\(scenario.id)")
        }
    }

    // MARK: - Solver-level parity (fast path)

    /// Solving a 1×1 composition from each scenario must select the corpus's
    /// expected color — pinning the solver's deterministic earliest-wins
    /// tie-breaking on the contiguous fast path, not just the scorer.
    func testSolverSelectsExpectedColorOnFastPath() throws {
        let corpus = try Self.loadCorpus()
        let solver = CompositionSolver(scorer: WeightedSquaredErrorScorer())

        for scenario in corpus.scenarios {
            guard canBuildSolverInput(scenario) else { continue }
            let result = try solver.solve(
                palette: palette(scenario),
                sourceGrids: solverGrids(scenario),
                weights: weights(scenario)
            )

            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, "\(scenario.id): solver selection")
            if let expectedError = scenario.expected.error {
                assertBitExact(result.error(x: 0, y: 0), expectedError, "\(scenario.id): solver error")
            } else {
                XCTAssertEqual(result.error(x: 0, y: 0), .infinity, "\(scenario.id): unmatched cell must report infinite error")
            }
            XCTAssertEqual(result.excludedCandidateCount, expectedExcludedCandidateCount(scenario), "\(scenario.id): excluded candidate count")
        }
    }

    // MARK: - Scenario → domain mapping

    private func scoreCandidate(_ scenario: ParityCorpus.Scenario, index: Int) -> ScorerResult {
        WeightedSquaredErrorScorer().score(
            candidate: palette(scenario)[index],
            target: target(scenario),
            weights: weights(scenario)
        )
    }

    private func earliestWinsSelection(_ scenario: ParityCorpus.Scenario) throws -> (index: Int, error: Double, tiedIndices: [Int], tieBroke: Bool) {
        let scorer = WeightedSquaredErrorScorer()
        var bestIndex: Int?
        var bestError = Double.infinity

        for (index, color) in palette(scenario).enumerated() {
            if case .score(let value) = scorer.score(candidate: color, target: target(scenario), weights: weights(scenario)),
               value < bestError {
                bestError = value
                bestIndex = index
            }
        }

        let index = try XCTUnwrap(bestIndex, "\(scenario.id): expected a selection")
        let tiedIndices = scenario.expected.scores.compactMap { entry -> Int? in
            guard case .value(let value) = entry.score, value.bitPattern == bestError.bitPattern else { return nil }
            return entry.index
        }
        return (index, bestError, tiedIndices, tiedIndices.count > 1)
    }

    private func scoresByScenarioID(_ corpus: ParityCorpus) throws -> [String: [(Int, Double)]] {
        var result: [String: [(Int, Double)]] = [:]
        for scenario in corpus.scenarios {
            result[scenario.id] = try scenario.expected.scores.map { entry in
                (entry.index, try XCTUnwrap(entry.score.value, "\(scenario.id) candidate \(entry.index) must carry a numeric score"))
            }
        }
        return result
    }

    private func palette(_ scenario: ParityCorpus.Scenario) -> [PaletteColor] {
        scenario.palette.enumerated().map { index, entry in
            PaletteColor(
                id: index,
                hex: entry.hexColor,
                rgb: RGBColor(hex: entry.hexColor)!,
                responses: responses(entry)
            )
        }
    }

    private func target(_ scenario: ParityCorpus.Scenario) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in scenario.target.channels ?? [:] {
            brightness[LightingCondition(rawValue: key)] = value
        }
        return TargetResponseVector(brightness)
    }

    /// Unknown light sources in the weights map (e.g. `ultraviolet`) are
    /// dropped, mirroring the server's weight filtering.
    private func weights(_ scenario: ParityCorpus.Scenario) -> ChannelWeights {
        func weight(_ key: String) -> Double { scenario.weights[key] ?? 0 }
        return ChannelWeights(
            white: weight("white"),
            red: weight("red"),
            green: weight("green"),
            blue: weight("blue"),
            lps: weight("lps")
        )
    }

    private func responses(_ entry: ParityCorpus.Scenario.Entry) -> [LightingCondition: IlluminationResponse] {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, value) in entry.channels ?? [:] {
            responses[LightingCondition(rawValue: key)] = IlluminationResponse(brightness: value)
        }
        return responses
    }

    // MARK: - Solver input helpers

    /// A source grid can only be built when the target itself is fully
    /// measured — a target missing a positive-weight channel (the
    /// `missing-target-excluded` scenario) has no source image equivalent.
    private func canBuildSolverInput(_ scenario: ParityCorpus.Scenario) -> Bool {
        let targetVector = target(scenario)
        return weights(scenario).activeConditions.allSatisfy { targetVector.value(for: $0) != nil }
    }

    private func solverGrids(_ scenario: ParityCorpus.Scenario) -> [LightingCondition: BrightnessGrid] {
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for (condition, _) in weights(scenario).activeEntries {
            if let value = target(scenario).value(for: condition) {
                grids[condition] = BrightnessGrid(width: 1, height: 1, fill: value)
            }
        }
        return grids
    }

    private func expectedExcludedCandidateCount(_ scenario: ParityCorpus.Scenario) -> Int {
        let active = weights(scenario).activeConditions
        return palette(scenario).filter { color in
            active.contains { color.brightness(for: $0) == nil }
        }.count
    }

    private func assertBitExact(_ actual: Double, _ expected: Double, _ context: String) {
        XCTAssertEqual(
            actual.bitPattern,
            expected.bitPattern,
            "\(context): expected \(expected.bitPattern) (\(expected)), got \(actual.bitPattern) (\(actual))"
        )
    }
}

// MARK: - Wire model

private enum ParityScoreValue: Equatable {
    case excluded
    case value(Double)
}

extension ParityScoreValue: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let excluded = try? container.decode(String.self), excluded == "excluded" {
            self = .excluded
        } else {
            self = .value(try container.decode(Double.self))
        }
    }

    var value: Double? {
        guard case .value(let double) = self else { return nil }
        return double
    }
}

private struct ParityCorpus: Decodable {
    struct Entry: Decodable {
        let index: Int?
        let hexColor: String
        let channels: [String: Double]?
    }

    struct ScoreEntry: Decodable {
        let index: Int
        let score: ParityScoreValue
    }

    struct Expected: Decodable {
        let scores: [ScoreEntry]
        let selectedIndex: Int?
        let selectedHexColor: String?
        let error: Double?
        let tieBroke: Bool?
        let tiedIndices: [Int]
    }

    struct Scenario: Decodable {
        let id: String
        let weights: [String: Double]
        let target: Entry
        let palette: [Entry]
        let expected: Expected
    }

    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
    let scenarios: [Scenario]
}
