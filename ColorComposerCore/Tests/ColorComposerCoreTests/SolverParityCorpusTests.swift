import Foundation
import XCTest
@testable import ColorComposerCore

/// Solver parity against the committed corpus.
///
/// The corpus (see `docs/solver-parity-corpus.md`) pins `WeightedSquaredErrorScorer`
/// selections — including tie cases, exclusions, and weight handling — to the
/// expected outputs produced by the Elixir `ColorMatching.WeightedSquaredError` /
/// `IlluminantMatching.best_match/4` reference implementation
/// (viamin/color_matching#111). Selections are asserted *exactly*: the winning
/// palette color id, the winning score, the earliest-wins tie policy, and the
/// excluded candidate ids must all match.
///
/// Cases run through the real `CompositionSolver` (1×1 source grids) so the
/// shipped selection path — eligibility pre-filter, fast-path scoring, and
/// tie-breaking — is what gets verified, not a re-implementation.
final class SolverParityCorpusTests: XCTestCase {
    private static let scoreAccuracy = 1e-9

    // MARK: - Corpus wire model (schema version 1)

    private struct ParityCorpus: Codable {
        let version: Int
        let scorer: String
        let cases: [ParityCase]
    }

    private struct ParityCase: Codable {
        let name: String
        let weights: [String: Double]
        let palette: [ParityColor]
        let targets: [[String: Double]]
        let expected: [ParityExpectation]
    }

    private struct ParityColor: Codable {
        let id: Int
        let hex: String
        let responses: [String: Double]
    }

    private struct ParityExpectation: Codable {
        let selectedId: Int?
        let score: Double?
        let tie: Bool?
        let excludedIds: [Int]?

        enum CodingKeys: String, CodingKey {
            case selectedId = "selected_id"
            case score
            case tie
            case excludedIds = "excluded_ids"
        }
    }

    // MARK: - Corpus loading

    /// Canonical location: committed fixture next to this test file. Overridable
    /// via the `SOLVER_PARITY_CORPUS` env var (used when refreshing the corpus
    /// from viamin/color_matching#111; see docs/solver-parity-corpus.md).
    private struct MissingCorpusError: Error, CustomStringConvertible {
        let searchedPaths: [String]
        var description: String {
            "Solver parity corpus not found. Searched: \(searchedPaths.joined(separator: ", ")). " +
            "See docs/solver-parity-corpus.md for the canonical location and refresh procedure."
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        var candidates: [URL] = [fixtureURL()]
        if let sibling = siblingCheckoutURL() {
            candidates.append(sibling)
        }
        if let path = ProcessInfo.processInfo.environment["SOLVER_PARITY_CORPUS"] {
            candidates.insert(URL(fileURLWithPath: path), at: 0)
        }

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return try decodeCorpus(at: url)
        }
        throw MissingCorpusError(searchedPaths: candidates.map(\.path))
    }

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver_parity_corpus.json")
    }

    /// A `color_matching` sibling checkout (repo root), if present.
    private func siblingCheckoutURL() -> URL? {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // ColorComposerCoreTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // ColorComposerCore
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("color_matching/priv/solver_parity_corpus.json")
    }

    private func decodeCorpus(at url: URL) throws -> ParityCorpus {
        let data = try Data(contentsOf: url)
        let corpus = try JSONDecoder().decode(ParityCorpus.self, from: data)
        XCTAssertEqual(corpus.version, 1, "Unsupported corpus schema version at \(url.path)")
        XCTAssertEqual(corpus.scorer, "weighted_squared_error", "This test target pins the weighted-squared-error scorer")
        return corpus
    }

    // MARK: - Corpus integrity

    func testCorpusIsPresentWellFormedAndCoversRequiredBehavior() throws {
        let corpus = try loadCorpus()
        XCTAssertFalse(corpus.cases.isEmpty, "Parity corpus must contain at least one case")

        var tieCases = 0
        var exclusionCases = 0
        var nullSelectionCases = 0
        for parityCase in corpus.cases {
            XCTAssertEqual(
                parityCase.targets.count, parityCase.expected.count,
                "Case '\(parityCase.name)': every target needs exactly one expected entry"
            )
            for (key, _) in parityCase.weights {
                XCTAssertNotNil(LightingCondition(rawValue: key), "Case '\(parityCase.name)': unknown weight key '\(key)'")
            }
            for color in parityCase.palette {
                for (key, value) in color.responses {
                    XCTAssertNotNil(LightingCondition(rawValue: key), "Case '\(parityCase.name)': unknown response key '\(key)'")
                    XCTAssertTrue((0...1).contains(value), "Case '\(parityCase.name)': brightness must be normalized 0...1")
                }
            }
            for target in parityCase.targets {
                for (key, value) in target {
                    XCTAssertNotNil(LightingCondition(rawValue: key), "Case '\(parityCase.name)': unknown target key '\(key)'")
                    XCTAssertTrue((0...1).contains(value), "Case '\(parityCase.name)': target brightness must be normalized 0...1")
                }
            }
            for expectation in parityCase.expected {
                if expectation.tie == true { tieCases += 1 }
                if expectation.excludedIds?.isEmpty == false { exclusionCases += 1 }
                if expectation.selectedId == nil { nullSelectionCases += 1 }
            }
        }
        XCTAssertGreaterThan(tieCases, 0, "Corpus must include at least one tie case (earliest-wins policy)")
        XCTAssertGreaterThan(exclusionCases, 0, "Corpus must include at least one candidate-exclusion case")
        XCTAssertGreaterThan(nullSelectionCases, 0, "Corpus must include at least one no-selection case (target missing a required channel)")
    }

    // MARK: - Parity

    func testSelectionsMatchCorpusExactly() throws {
        let corpus = try loadCorpus()
        var verifiedTargets = 0

        for parityCase in corpus.cases {
            let palette = try makePalette(parityCase)
            let weights = makeWeights(parityCase.weights)
            let scorer = WeightedSquaredErrorScorer()
            XCTAssertFalse(
                weights.activeEntries.isEmpty,
                "Case '\(parityCase.name)': at least one weight must be > 0"
            )

            for (index, targetDict) in parityCase.targets.enumerated() {
                let expectation = parityCase.expected[index]
                let target = makeTarget(targetDict)
                let label = "Case '\(parityCase.name)' target \(index)"

                // Candidate-side exclusion parity: every excluded_ids entry must
                // be unrankable for this target; anything else must be rankable.
                for color in palette {
                    let isExcluded = scorer.score(candidate: color, target: target, weights: weights) == .excluded
                    let shouldBeExcluded = expectation.excludedIds?.contains(color.id) ?? false
                    XCTAssertEqual(
                        isExcluded, shouldBeExcluded,
                        "\(label): candidate \(color.id) exclusion mismatch (missing is never zero brightness)"
                    )
                }

                if let requiredMissing = missingRequiredCondition(targetDict, weights: parityCase.weights) {
                    // Target-side exclusion: no candidate can rank when the
                    // target lacks a required channel, so no selection exists.
                    XCTAssertNil(expectation.selectedId, "\(label): expected no selection, but corpus names one")
                    XCTAssertNil(
                        selectBest(palette: palette, target: target, weights: weights)?.id,
                        "\(label): a target missing required channel '\(requiredMissing.rawValue)' must match nothing"
                    )
                    continue
                }

                let result = try CompositionSolver(scorer: scorer).solve(
                    palette: palette,
                    sourceGrids: makeGrids(targetDict, weights: weights),
                    weights: weights
                )
                let cellIndex = result.colorIndices.first.flatMap { $0 }

                if let expectedId = expectation.selectedId {
                    let selectedIndex = try XCTUnwrap(
                        cellIndex,
                        "\(label): solver returned no selection"
                    )
                    XCTAssertEqual(
                        palette[selectedIndex].id, expectedId,
                        "\(label): selected palette id mismatch (earliest-wins tie policy)"
                    )
                } else {
                    XCTAssertNil(
                        cellIndex,
                        "\(label): corpus expects no selection, but solver selected \(cellIndex.map { palette[$0].id } ?? -1)"
                    )
                }

                if let expectedScore = expectation.score {
                    XCTAssertEqual(
                        result.errors.first ?? .infinity, expectedScore,
                        accuracy: Self.scoreAccuracy,
                        "\(label): winning score mismatch"
                    )
                }

                if let expectTie = expectation.tie {
                    let winningScore = result.errors.first ?? .infinity
                    var tiedIds: [Int] = []
                    for color in palette {
                        if case .score(let value) = scorer.score(candidate: color, target: target, weights: weights),
                           abs(value - winningScore) < Self.scoreAccuracy {
                            tiedIds.append(color.id)
                        }
                    }
                    XCTAssertEqual(
                        tiedIds.count > 1, expectTie,
                        "\(label): tie mismatch (candidates at the winning score: \(tiedIds))"
                    )
                }
                verifiedTargets += 1
            }
        }
        XCTAssertGreaterThan(verifiedTargets, 0, "Corpus produced no solver-level parity assertions")
    }

    func testExcludedCandidateCountMatchesCorpus() throws {
        let corpus = try loadCorpus()

        for parityCase in corpus.cases {
            let weights = makeWeights(parityCase.weights)
            let excludedIds = Set(parityCase.expected.compactMap(\.excludedIds).flatMap { $0 })
            // Find the first target that carries every required channel; only
            // those can run through the grid-driven solver.
            guard let runnableTarget = parityCase.targets.first(where: {
                missingRequiredCondition($0, weights: parityCase.weights) == nil
            }) else { continue }

            let result = try CompositionSolver().solve(
                palette: try makePalette(parityCase),
                sourceGrids: makeGrids(runnableTarget, weights: weights),
                weights: weights
            )
            XCTAssertEqual(
                result.excludedCandidateCount, excludedIds.count,
                "Case '\(parityCase.name)': solver excluded-candidate count must match the corpus"
            )
        }
    }

    // MARK: - Corpus → domain conversion

    private func makePalette(_ parityCase: ParityCase) throws -> [PaletteColor] {
        try parityCase.palette.map { color in
            var responses: [LightingCondition: IlluminationResponse] = [:]
            for (key, value) in color.responses {
                let condition = try XCTUnwrap(LightingCondition(rawValue: key), "Unknown light source '\(key)'")
                responses[condition] = IlluminationResponse(brightness: value)
            }
            let rgb = try XCTUnwrap(RGBColor(hex: color.hex), "Invalid hex '\(color.hex)' in corpus")
            return PaletteColor(id: color.id, hex: color.hex, rgb: rgb, responses: responses)
        }
    }

    private func makeWeights(_ dict: [String: Double]) -> ChannelWeights {
        func value(_ key: String) -> Double { dict[key] ?? 0 }
        return ChannelWeights(
            white: value("white"), red: value("red"), green: value("green"),
            blue: value("blue"), lps: value("lps")
        )
    }

    private func makeTarget(_ dict: [String: Double]) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in dict {
            if let condition = LightingCondition(rawValue: key) {
                brightness[condition] = value
            }
        }
        return TargetResponseVector(brightness)
    }

    /// One 1×1 source grid per active condition, so the solver's real selection
    /// path scores exactly this corpus target.
    private func makeGrids(
        _ target: [String: Double],
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid] {
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for (condition, weight) in weights.activeEntries where weight > 0 {
            grids[condition] = BrightnessGrid(width: 1, height: 1, fill: target[condition.rawValue] ?? 0)
        }
        return grids
    }

    /// The active (weight > 0) condition the target dict lacks, if any.
    private func missingRequiredCondition(
        _ target: [String: Double],
        weights: [String: Double]
    ) -> LightingCondition? {
        weights
            .filter { $0.value > 0 }
            .compactMap { LightingCondition(rawValue: $0.key) }
            .first { target[$0.rawValue] == nil }
    }

    /// Earliest-wins best candidate, mirroring `IlluminantMatching.best_match/4`
    /// and `CompositionSolver`'s selection policy. Used for scorer-level
    /// assertions the grid-driven solver path cannot express.
    private func selectBest(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> PaletteColor? {
        let scorer = WeightedSquaredErrorScorer()
        var best: PaletteColor?
        var bestScore = Double.infinity
        for color in palette {
            guard case .score(let score) = scorer.score(candidate: color, target: target, weights: weights),
                  score < bestScore
            else { continue }
            bestScore = score
            best = color
        }
        return best
    }
}
