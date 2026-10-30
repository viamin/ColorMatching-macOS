import Foundation
import XCTest
@testable import ColorComposerCore

/// Solver parity against the committed corpus (issue #39).
///
/// Loads `Fixtures/ParityCorpus/weighted_squared_error_v1.json` — the
/// committed reference corpus for the Elixir `ColorMatching.WeightedSquaredError`
/// solver (viamin/color_matching#111) — and asserts that
/// `WeightedSquaredErrorScorer` reproduces the reference selections exactly:
///
/// - selection = lowest weighted squared error over channels with weight > 0,
/// - ties resolve to the earliest palette index (`best_match` policy),
/// - a candidate or target missing a measurement for a required channel is
///   excluded, never treated as zero brightness,
/// - channels with weight 0 neither require a measurement nor contribute,
/// - and `CompositionSolver` agrees with the scorer-driven selection.
///
/// See `docs/solver-parity-corpus.md` for the corpus schema and the refresh
/// procedure when an updated corpus lands upstream.
final class SolverParityCorpusTests: XCTestCase {
    // MARK: - Corpus schema (mirrors docs/solver-parity-corpus.md)

    private struct ParityCorpus: Codable {
        let corpusVersion: Int
        let source: String
        let algorithm: String
        let selectionPolicy: String
        let cases: [ParityCase]
    }

    private struct ParityCase: Codable {
        let id: String
        let description: String
        let tags: [String]
        let weights: [String: Double]
        let target: [String: Double]
        let palette: [ParityCandidate]
        let expected: ParityExpectation
    }

    private struct ParityCandidate: Codable {
        let id: Int
        let name: String?
        let hex: String
        let responses: [String: Double]
    }

    private struct ParityExpectation: Codable {
        let selectedIndex: Int?
        let selectedId: Int?
        let score: Double?
        let excludedIndices: [Int]?
        let tiedIndices: [Int]?
    }

    // MARK: - Corpus location

    /// Resolves symlinks so the fixture is found even when the test tree is
    /// symlinked into a harness package (as `bin/lint` does on Linux hosts).
    private static var testsDirectory: URL {
        URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
    }

    private static var corpusURL: URL {
        testsDirectory
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("ParityCorpus", isDirectory: true)
            .appendingPathComponent("weighted_squared_error_v1.json")
    }

    private func loadCorpus() throws -> ParityCorpus {
        let url = Self.corpusURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(
                domain: "SolverParityCorpusTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Parity corpus fixture is missing at \(url.path)"]
            )
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: data)
    }

    // MARK: - Corpus → domain conversion

    private func conditions(_ dict: [String: Double], caseID: String) -> [LightingCondition: Double] {
        var resolved: [LightingCondition: Double] = [:]
        for (key, value) in dict {
            guard let condition = LightingCondition(rawValue: key) else {
                XCTFail("case \(caseID): unknown lighting condition key \"\(key)\" — canonical keys are \(LightingCondition.allCases.map(\.rawValue))")
                continue
            }
            resolved[condition] = value
        }
        return resolved
    }

    private func makeWeights(_ dict: [String: Double], caseID: String) -> ChannelWeights {
        let resolved = conditions(dict, caseID: caseID)
        return ChannelWeights(
            white: resolved[.white] ?? 0,
            red: resolved[.red] ?? 0,
            green: resolved[.green] ?? 0,
            blue: resolved[.blue] ?? 0,
            lps: resolved[.lps] ?? 0
        )
    }

    private func makeTarget(_ dict: [String: Double], caseID: String) -> TargetResponseVector {
        TargetResponseVector(conditions(dict, caseID: caseID))
    }

    private func makeColor(_ candidate: ParityCandidate, caseID: String) -> PaletteColor {
        let resolved = conditions(candidate.responses, caseID: caseID)
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (condition, brightness) in resolved {
            responses[condition] = IlluminationResponse(brightness: brightness)
        }
        guard let rgb = RGBColor(hex: candidate.hex) else {
            XCTFail("case \(caseID): palette color \(candidate.id) has unparseable hex \"\(candidate.hex)\"")
            return PaletteColor(id: candidate.id, name: candidate.name, hex: candidate.hex, rgb: RGBColor(red: 0, green: 0, blue: 0), responses: responses)
        }
        return PaletteColor(id: candidate.id, name: candidate.name, hex: candidate.hex, rgb: rgb, responses: responses)
    }

    private func makePalette(_ case_: ParityCase) -> [PaletteColor] {
        case_.palette.map { makeColor($0, caseID: case_.id) }
    }

    /// Reference selection policy mirrored from the Elixir solver
    /// (`IlluminantMatching.best_match/4`): the strictly lowest score wins,
    /// so the earliest palette index wins any tie. Returns the winner, its
    /// score, the excluded candidate indices, and the indices tied at the
    /// minimum score.
    private func selectBestMatch(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> (selectedIndex: Int?, score: Double?, excludedIndices: [Int], tiedIndices: [Int]) {
        let scorer = WeightedSquaredErrorScorer()
        var selectedIndex: Int?
        var bestScore = Double.infinity
        var excludedIndices: [Int] = []
        var scores: [Int: Double] = [:]

        for (index, color) in palette.enumerated() {
            switch scorer.score(candidate: color, target: target, weights: weights) {
            case .excluded:
                excludedIndices.append(index)
            case .score(let value):
                scores[index] = value
                if value < bestScore {
                    bestScore = value
                    selectedIndex = index
                }
            }
        }

        let tiedIndices = selectedIndex == nil ? [] : scores.filter { $0.value == bestScore }.keys.sorted()
        return (selectedIndex, selectedIndex == nil ? nil : bestScore, excludedIndices, tiedIndices)
    }

    // MARK: - Corpus integrity

    func testCorpusDeclaresExpectedAlgorithmAndPolicy() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.corpusVersion, 1, "Unsupported corpus_version — update the loader and docs/solver-parity-corpus.md together")
        XCTAssertEqual(corpus.algorithm, "weighted_squared_error")
        XCTAssertEqual(corpus.selectionPolicy, "min_score_earliest_index_wins")
        XCTAssertFalse(corpus.cases.isEmpty, "A parity corpus with no cases enforces nothing")
        XCTAssertEqual(
            Set(corpus.cases.map(\.id)).count,
            corpus.cases.count,
            "Corpus case ids must be unique"
        )
    }

    /// The corpus must keep covering the parity-relevant behaviors: ties,
    /// exclusions (candidate- and target-side), no-selection outcomes, and
    /// weight handling. A refresh that drops a category fails here instead of
    /// silently shrinking parity coverage.
    func testCorpusCoversRequiredScenarioCategories() throws {
        let corpus = try loadCorpus()
        let tags = Set(corpus.cases.flatMap(\.tags))
        let required: Set<String> = [
            "tie",
            "order_dependence",
            "exclusion",
            "missing_measurement",
            "missing_target",
            "no_selection",
            "zero_weight",
            "weights",
            "precision"
        ]
        let missing = required.subtracting(tags)
        XCTAssertTrue(
            missing.isEmpty,
            "Corpus lost scenario categories: \(missing.sorted()) — see docs/solver-parity-corpus.md"
        )
    }

    func testCorpusCasesAreWellFormed() throws {
        let corpus = try loadCorpus()

        for case_ in corpus.cases {
            let weights = makeWeights(case_.weights, caseID: case_.id)
            let palette = makePalette(case_)

            XCTAssertFalse(palette.isEmpty, "case \(case_.id): palette must not be empty")
            XCTAssertFalse(
                weights.activeConditions.isEmpty,
                "case \(case_.id): at least one channel weight must be > 0 (a corpus case with no active channel exercises no parity behavior)"
            )
            XCTAssertFalse(
                case_.target.isEmpty,
                "case \(case_.id): target must carry at least one channel"
            )
            XCTAssertEqual(
                Set(palette.map(\.id)).count,
                palette.count,
                "case \(case_.id): palette color ids must be unique so selections are identifiable"
            )

            if let selectedIndex = case_.expected.selectedIndex {
                XCTAssertTrue(
                    palette.indices.contains(selectedIndex),
                    "case \(case_.id): selected_index \(selectedIndex) is outside the palette"
                )
                if palette.indices.contains(selectedIndex) {
                    XCTAssertEqual(
                        palette[selectedIndex].id,
                        case_.expected.selectedId,
                        "case \(case_.id): selected_id must identify the color at selected_index"
                    )
                }
            }
        }
    }

    // MARK: - Parity: selection and scores

    /// Every corpus case: the Swift scorer's selection (winner, score,
    /// exclusions, ties) must match the reference expectations exactly.
    func testSelectionMatchesCorpusExpectations() throws {
        let corpus = try loadCorpus()

        for case_ in corpus.cases {
            let weights = makeWeights(case_.weights, caseID: case_.id)
            let target = makeTarget(case_.target, caseID: case_.id)
            let palette = makePalette(case_)
            let outcome = selectBestMatch(palette: palette, target: target, weights: weights)

            XCTAssertEqual(
                outcome.selectedIndex,
                case_.expected.selectedIndex,
                "case \(case_.id): selected palette index"
            )
            if let expectedScore = case_.expected.score {
                XCTAssertEqual(
                    outcome.score ?? Double.infinity,
                    expectedScore,
                    accuracy: 1e-9,
                    "case \(case_.id): winning score"
                )
            }
            XCTAssertEqual(
                outcome.excludedIndices,
                case_.expected.excludedIndices ?? [],
                "case \(case_.id): excluded candidate indices"
            )
            if let tiedIndices = case_.expected.tiedIndices {
                XCTAssertEqual(
                    outcome.tiedIndices,
                    tiedIndices,
                    "case \(case_.id): indices tied at the minimum score"
                )
            }
        }
    }

    /// Tie cases: every candidate listed as tied must produce a bit-equal
    /// minimum score, must precede any strictly-worse candidate, and the
    /// earliest tied index must be the selection.
    func testTieCasesSelectTheEarliestTiedIndex() throws {
        let corpus = try loadCorpus()
        let tieCases = corpus.cases.filter { $0.tags.contains("tie") }
        XCTAssertFalse(tieCases.isEmpty)

        for case_ in tieCases {
            guard let tiedIndices = case_.expected.tiedIndices else {
                XCTFail("case \(case_.id): tie cases must declare tied_indices")
                continue
            }
            XCTAssertGreaterThanOrEqual(tiedIndices.count, 2, "case \(case_.id): a tie needs at least two candidates")

            let weights = makeWeights(case_.weights, caseID: case_.id)
            let target = makeTarget(case_.target, caseID: case_.id)
            let palette = makePalette(case_)
            let outcome = selectBestMatch(palette: palette, target: target, weights: weights)

            guard let winningScore = outcome.score else {
                XCTFail("case \(case_.id): a tie case must have a winner")
                continue
            }

            XCTAssertEqual(outcome.tiedIndices, tiedIndices, "case \(case_.id): tied set")
            XCTAssertEqual(
                outcome.selectedIndex,
                tiedIndices.first,
                "case \(case_.id): the earliest tied index must win the tie"
            )
            for index in tiedIndices {
                guard palette.indices.contains(index) else {
                    XCTFail("case \(case_.id): tied index \(index) is outside the palette")
                    continue
                }
                XCTAssertEqual(
                    outcomeScore(of: palette[index], target: target, weights: weights),
                    winningScore,
                    "case \(case_.id): tied candidate at index \(index) must score exactly the winning score"
                )
            }
            for index in palette.indices where !tiedIndices.contains(index) {
                guard let score = outcomeScore(of: palette[index], target: target, weights: weights) else {
                    XCTFail("case \(case_.id): non-tied candidate at index \(index) must be rankable")
                    continue
                }
                XCTAssertGreaterThan(
                    score,
                    winningScore,
                    "case \(case_.id): non-tied candidate at index \(index) must score strictly worse than the tied winner"
                )
            }
        }
    }

    private func outcomeScore(
        of candidate: PaletteColor,
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> Double? {
        guard case .score(let value) = WeightedSquaredErrorScorer().score(
            candidate: candidate,
            target: target,
            weights: weights
        ) else {
            return nil
        }
        return value
    }

    /// Exclusion cases: candidates the corpus marks excluded must be reported
    /// `.excluded` by the scorer, and — when the target itself is complete —
    /// every other candidate must be rankable. When the target is missing a
    /// required channel, every candidate must be excluded.
    func testExclusionSemanticsMatchTheCorpus() throws {
        let corpus = try loadCorpus()
        let exclusionCases = corpus.cases.filter { $0.tags.contains("exclusion") }
        XCTAssertFalse(exclusionCases.isEmpty)

        for case_ in exclusionCases {
            let weights = makeWeights(case_.weights, caseID: case_.id)
            let target = makeTarget(case_.target, caseID: case_.id)
            let palette = makePalette(case_)
            let targetIsComplete = weights.activeConditions.allSatisfy { target.value(for: $0) != nil }
            let expectedExcluded = Set(case_.expected.excludedIndices ?? [])

            for index in palette.indices {
                let isExcluded = outcomeScore(of: palette[index], target: target, weights: weights) == nil
                if targetIsComplete {
                    XCTAssertEqual(
                        isExcluded,
                        expectedExcluded.contains(index),
                        "case \(case_.id): candidate \(palette[index].id) at index \(index) exclusion state"
                    )
                } else {
                    XCTAssertTrue(
                        isExcluded,
                        "case \(case_.id): target is missing a required channel, so candidate \(palette[index].id) must be excluded"
                    )
                }
            }
        }
    }

    // MARK: - Parity: solver agreement

    /// The corpus selection must be what the shipped solve path produces:
    /// `CompositionSolver` with its default `WeightedSquaredErrorScorer` over
    /// a 1×1 composition per case. Cases whose target vector is missing a
    /// required channel cannot be expressed as source grids and are skipped
    /// here (they are covered by the scorer-level tests above).
    func testSolverAgreesWithCorpusSelections() throws {
        let corpus = try loadCorpus()

        for case_ in corpus.cases {
            let weights = makeWeights(case_.weights, caseID: case_.id)
            let target = makeTarget(case_.target, caseID: case_.id)
            let palette = makePalette(case_)

            guard weights.activeConditions.allSatisfy({ target.value(for: $0) != nil }) else {
                continue
            }

            var sourceGrids: [LightingCondition: BrightnessGrid] = [:]
            for condition in weights.activeConditions {
                sourceGrids[condition] = BrightnessGrid(
                    width: 1,
                    height: 1,
                    fill: target.value(for: condition) ?? 0
                )
            }

            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: sourceGrids,
                weights: weights
            )

            XCTAssertEqual(
                result.colorIndex(x: 0, y: 0),
                case_.expected.selectedIndex,
                "case \(case_.id): solver selection"
            )
            XCTAssertEqual(
                result.unmatchedCellCount,
                case_.expected.selectedIndex == nil ? 1 : 0,
                "case \(case_.id): unmatched cells"
            )
            if let expectedScore = case_.expected.score, case_.expected.selectedIndex != nil {
                XCTAssertEqual(
                    result.error(x: 0, y: 0),
                    expectedScore,
                    accuracy: 1e-9,
                    "case \(case_.id): solver error"
                )
            }
            if let excludedIndices = case_.expected.excludedIndices {
                XCTAssertEqual(
                    result.excludedCandidateCount,
                    excludedIndices.count,
                    "case \(case_.id): solver-excluded candidate count"
                )
            }
        }
    }
}
