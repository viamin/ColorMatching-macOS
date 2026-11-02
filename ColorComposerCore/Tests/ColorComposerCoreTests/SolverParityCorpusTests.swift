import Foundation
import XCTest
@testable import ColorComposerCore

/// Wire schema of the solver parity corpus committed from
/// `viamin/color_matching` (parity corpus PR). The corpus pins the Elixir
/// `WeightedSquaredError` solver's selections so the Swift mirror
/// (`WeightedSquaredErrorScorer` + `CompositionSolver`) can be proven — or
/// disproven — case by case. See `docs/solver-parity-corpus.md`.
struct SolverParityCorpus: Codable {
    struct Case: Codable {
        struct Color: Codable {
            let id: Int
            let responses: [String: Double]
        }

        struct Expected: Codable {
            /// The palette color the Elixir solver selected, or `nil` when
            /// every candidate was excluded (unmatched target).
            let selectedColorId: Int?
            /// The weighted squared error of the selection.
            let score: Double?
            /// `true` when ≥ 2 candidates share the minimal score and the
            /// winner is decided by deterministic tie-breaking.
            let tie: Bool?
            /// Candidates excluded for missing a required measurement.
            let excludedColorIds: [Int]?
        }

        let id: String
        let description: String?
        let weights: [String: Double]
        let palette: [Color]
        let target: [String: Double]
        let expected: Expected
    }

    let version: Int
    let generator: String?
    let cases: [Case]
}

/// Runs one corpus case through the Swift solver mirror and reports every
/// parity deviation found. An empty result means the case matches exactly.
enum SolverParityRunner {
    /// Scores are compared to the corpus with this absolute tolerance: both
    /// solvers use IEEE-754 doubles, but summation order may differ slightly.
    static let scoreAccuracy = 1e-9
    /// Two scores closer than this are considered tied — below this,
    /// double noise (not solver semantics) decides the winner.
    static let tieTolerance = 1e-12

    static func problems(in corpusCase: SolverParityCorpus.Case) -> [String] {
        var problems: [String] = []
        let prefix = "case \(corpusCase.id)"

        guard let weights = weights(from: corpusCase.weights, prefix: prefix, problems: &problems),
              let palette = palette(from: corpusCase.palette, prefix: prefix, problems: &problems),
              let target = target(from: corpusCase.target, weights: weights, prefix: prefix, problems: &problems)
        else { return problems }

        let scored = scoreCandidates(palette: palette, target: target, weights: weights)
        problems += exclusionProblems(scored: scored, expected: corpusCase.expected, prefix: prefix)
        problems += selectionProblems(scored: scored, expected: corpusCase.expected, prefix: prefix)
        problems += solverProblems(
            palette: palette, target: target, weights: weights, expected: corpusCase.expected, prefix: prefix
        )
        return problems
    }

    // MARK: - Corpus decoding

    static func decode(_ data: Data) throws -> SolverParityCorpus {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SolverParityCorpus.self, from: data)
    }

    // MARK: - Conversion

    private static func weights(
        from raw: [String: Double],
        prefix: String,
        problems: inout [String]
    ) -> ChannelWeights? {
        var values: [LightingCondition: Double] = [:]
        for (key, value) in raw {
            guard let condition = LightingCondition(rawValue: key) else {
                problems.append("\(prefix): unknown weight key \"\(key)\"")
                return nil
            }
            values[condition] = value
        }
        return ChannelWeights(
            white: values[.white] ?? 0,
            red: values[.red] ?? 0,
            green: values[.green] ?? 0,
            blue: values[.blue] ?? 0,
            lps: values[.lps] ?? 0
        )
    }

    private static func palette(
        from raw: [SolverParityCorpus.Case.Color],
        prefix: String,
        problems: inout [String]
    ) -> [PaletteColor]? {
        var colors: [PaletteColor] = []
        for entry in raw {
            var responses: [LightingCondition: IlluminationResponse] = [:]
            for (key, brightness) in entry.responses {
                guard let condition = LightingCondition(rawValue: key) else {
                    problems.append("\(prefix): color \(entry.id) has unknown response key \"\(key)\"")
                    return nil
                }
                responses[condition] = IlluminationResponse(brightness: brightness)
            }
            colors.append(PaletteColor(id: entry.id, hex: "#000000", rgb: RGBColor(hex: "#000000")!, responses: responses))
        }
        guard !colors.isEmpty else {
            problems.append("\(prefix): palette must not be empty")
            return nil
        }
        return colors
    }

    /// Corpus targets must carry a value for every active condition: the
    /// solver always builds complete target vectors from source grids.
    private static func target(
        from raw: [String: Double],
        weights: ChannelWeights,
        prefix: String,
        problems: inout [String]
    ) -> TargetResponseVector? {
        var values: [LightingCondition: Double] = [:]
        for (key, value) in raw {
            guard let condition = LightingCondition(rawValue: key) else {
                problems.append("\(prefix): unknown target key \"\(key)\"")
                return nil
            }
            values[condition] = value
        }
        let missing = weights.activeConditions.filter { values[$0] == nil }
        guard missing.isEmpty else {
            problems.append("\(prefix): target is missing active condition(s) \(missing.map(\.rawValue))")
            return nil
        }
        return TargetResponseVector(values)
    }

    // MARK: - Scorer parity

    private struct ScoredCandidate {
        let color: PaletteColor
        let score: Double?
    }

    private static func scoreCandidates(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> [ScoredCandidate] {
        let scorer = WeightedSquaredErrorScorer()
        return palette.map { color in
            switch scorer.score(candidate: color, target: target, weights: weights) {
            case .excluded: return ScoredCandidate(color: color, score: nil)
            case .score(let value): return ScoredCandidate(color: color, score: value)
            }
        }
    }

    private static func exclusionProblems(
        scored: [ScoredCandidate],
        expected: SolverParityCorpus.Case.Expected,
        prefix: String
    ) -> [String] {
        let actualExcluded = scored.filter { $0.score == nil }.map(\.color.id).sorted()
        let expectedExcluded = (expected.excludedColorIds ?? []).sorted()
        guard actualExcluded == expectedExcluded else {
            return ["\(prefix): excluded ids \(actualExcluded) do not match expected \(expectedExcluded)"]
        }
        return []
    }

    private static func selectionProblems(
        scored: [ScoredCandidate],
        expected: SolverParityCorpus.Case.Expected,
        prefix: String
    ) -> [String] {
        let rankable = scored.filter { $0.score != nil }
        guard let selectedID = expected.selectedColorId else {
            guard rankable.isEmpty else {
                return ["\(prefix): expected every candidate excluded, but \(rankable.count) remain rankable"]
            }
            return []
        }
        guard let selected = rankable.first(where: { $0.color.id == selectedID }) else {
            return ["\(prefix): expected selection \(selectedID) is not a rankable candidate"]
        }

        var problems: [String] = []
        let score = selected.score!
        if let expectedScore = expected.score {
            if abs(score - expectedScore) > scoreAccuracy {
                problems.append("\(prefix): score \(score) does not match expected \(expectedScore)")
            }
        } else {
            problems.append("\(prefix): expected score is missing for selection \(selectedID)")
        }

        guard let minScore = rankable.map({ $0.score! }).min() else { return problems }
        if score > minScore + tieTolerance {
            problems.append("\(prefix): selection \(selectedID) score \(score) is not the minimum \(minScore)")
        }

        let tied = rankable.filter { abs($0.score! - minScore) <= tieTolerance }
        if expected.tie == true {
            if tied.count < 2 {
                problems.append("\(prefix): expected a tie, but only one candidate reaches the minimum score")
            }
            let earliestTied = tied.first!.color.id
            if selectedID != earliestTied {
                problems.append("\(prefix): tie must select the earliest candidate \(earliestTied), got \(selectedID)")
            }
        } else if tied.count > 1 {
            problems.append("\(prefix): expected a unique winner, but \(tied.count) candidates tie at \(minScore)")
        }
        return problems
    }

    // MARK: - Solver parity (selection + tie-breaking through CompositionSolver)

    private static func solverProblems(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights,
        expected: SolverParityCorpus.Case.Expected,
        prefix: String
    ) -> [String] {
        let grids = weights.activeConditions.reduce(into: [LightingCondition: BrightnessGrid]()) { grids, condition in
            grids[condition] = BrightnessGrid(width: 1, height: 1, values: [target.value(for: condition) ?? 0])
        }
        guard let result = try? CompositionSolver().solve(
            palette: palette, sourceGrids: grids, weights: weights
        ) else {
            return ["\(prefix): solver threw on a corpus case"]
        }

        var problems: [String] = []
        let selected = result.colorIndices.first ?? nil
        if let expectedID = expected.selectedColorId {
            guard let index = selected, palette[index].id == expectedID else {
                let actual = selected.map { String(palette[$0].id) } ?? "nothing"
                return ["\(prefix): solver selected \(actual), expected \(expectedID)"]
            }
            if let expectedScore = expected.score, let error = result.errors.first,
               abs(error - expectedScore) > scoreAccuracy {
                problems.append("\(prefix): solver error \(error) does not match expected \(expectedScore)")
            }
        } else if selected != nil {
            problems.append("\(prefix): solver selected a candidate but every candidate should be excluded")
        }

        let expectedExcludedCount = (expected.excludedColorIds ?? []).count
        if result.excludedCandidateCount != expectedExcludedCount {
            problems.append(
                "\(prefix): solver excluded \(result.excludedCandidateCount) candidates, expected \(expectedExcludedCount)"
            )
        }
        return problems
    }
}


/// Loads the committed parity corpus and enforces that the Swift solver
/// mirror reproduces the Elixir `WeightedSquaredError` selections exactly —
/// scores, exclusions, weight handling, and deterministic tie-breaking.
final class SolverParityCorpusTests: XCTestCase {
    private static let committedCorpusPath = committedCorpusURL()

    private static func committedCorpusURL() -> URL {
        let overrides = [ProcessInfo.processInfo.environment["SOLVER_PARITY_CORPUS_PATH"]]
        for case let path? in overrides where !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return testFileDirectory()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("solver_parity_corpus.json")
    }

    /// Resolves through symlinks so the fixture is found even when the test
    /// target directory is symlinked into a lint harness package.
    private static func testFileDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
    }

    // MARK: - Committed corpus

    func testCommittedCorpusExists() throws {
        let url = Self.committedCorpusPath
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("""
            Solver parity corpus is not committed at \(url.path). \
            Commit the corpus generated by viamin/color_matching (PR #111) there \
            and refresh it per docs/solver-parity-corpus.md.
            """)
            return
        }
    }

    func testCommittedCorpusMatchesSwiftSolverSelections() throws {
        let url = Self.committedCorpusPath
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("Corpus not committed yet (see testCommittedCorpusExists)")
        }
        let corpus = try SolverParityRunner.decode(data)

        XCTAssertEqual(corpus.version, 1, "Unsupported corpus schema version")
        XCTAssertFalse(corpus.cases.isEmpty, "Corpus must contain at least one case")

        var problems: [String] = []
        for corpusCase in corpus.cases {
            problems += SolverParityRunner.problems(in: corpusCase)
        }
        XCTAssertTrue(problems.isEmpty, "Solver parity failures:\n" + problems.joined(separator: "\n"))
    }

    /// The corpus must keep exercising the two behaviors where silent drift
    /// is easiest: deterministic tie-breaking and required-measurement
    /// exclusion. A corpus of only happy-path unique winners proves nothing.
    func testCommittedCorpusCoversTiesAndExclusions() throws {
        let url = Self.committedCorpusPath
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("Corpus not committed yet (see testCommittedCorpusExists)")
        }
        let corpus = try SolverParityRunner.decode(data)

        XCTAssertTrue(
            corpus.cases.contains { $0.expected.tie == true },
            "Corpus must contain at least one tie case"
        )
        XCTAssertTrue(
            corpus.cases.contains { !($0.expected.excludedColorIds ?? []).isEmpty },
            "Corpus must contain at least one exclusion case"
        )
    }

    // MARK: - Harness self-check (green today)

    /// Proves the harness itself is correct against hand-computed cases that
    /// mirror the Elixir `WeightedSquaredError` doctest and the solver's
    /// documented tie/exclusion semantics — so corpus failures later mean
    /// solver drift, not harness bugs.
    func testHarnessVerifiesHandComputedCases() throws {
        let corpus = try SolverParityRunner.decode(Data(Self.handComputedCorpus.utf8))

        var problems: [String] = []
        for corpusCase in corpus.cases {
            problems += SolverParityRunner.problems(in: corpusCase)
        }
        XCTAssertTrue(problems.isEmpty, "Harness is broken:\n" + problems.joined(separator: "\n"))
    }

    /// The harness must actually be able to fail: mutating the expected
    /// selection of the hand-computed tie case must be reported.
    func testHarnessDetectsAMutatedExpectedSelection() throws {
        let mutated = Self.handComputedCorpus.replacingOccurrences(
            of: "\"selected_color_id\": 7",
            with: "\"selected_color_id\": 8"
        )
        let corpus = try SolverParityRunner.decode(Data(mutated.utf8))
        let tieCase = try XCTUnwrap(corpus.cases.first { $0.id == "tie-earliest-wins" })

        let problems = SolverParityRunner.problems(in: tieCase)

        XCTAssertFalse(problems.isEmpty, "Harness must report the mutated tie winner")
    }

    private static let handComputedCorpus = """
    {
      "version": 1,
      "generator": "hand-computed harness self-check",
      "cases": [
        {
          "id": "elixir-doctest",
          "description": "The Elixir WeightedSquaredError doctest: expected 0.205.",
          "weights": {"white": 0.5, "red": 1.0, "green": 1.0, "blue": 0.0, "lps": 1.5},
          "palette": [
            {"id": 1, "responses": {"white": 0.5, "red": 0.1, "green": 0.4, "blue": 0.0, "lps": 0.3}}
          ],
          "target": {"white": 0.8, "red": 0.2, "green": 0.7, "blue": 0.1, "lps": 0.5},
          "expected": {"selected_color_id": 1, "score": 0.205, "tie": false, "excluded_color_ids": []}
        },
        {
          "id": "tie-earliest-wins",
          "description": "Two colors equidistant from the target; the earliest palette entry must win.",
          "weights": {"red": 1.0},
          "palette": [
            {"id": 7, "responses": {"red": 0.4}},
            {"id": 8, "responses": {"red": 0.6}}
          ],
          "target": {"red": 0.5},
          "expected": {"selected_color_id": 7, "score": 0.01, "tie": true, "excluded_color_ids": []}
        },
        {
          "id": "exclusion-missing-required-channel",
          "description": "A color missing a required measurement is excluded, never treated as zero.",
          "weights": {"red": 1.0, "green": 1.0},
          "palette": [
            {"id": 3, "responses": {"red": 0.5}},
            {"id": 4, "responses": {"red": 0.5, "green": 0.5}}
          ],
          "target": {"red": 0.5, "green": 0.5},
          "expected": {"selected_color_id": 4, "score": 0.0, "tie": false, "excluded_color_ids": [3]}
        },
        {
          "id": "zero-weight-channel-not-required",
          "description": "Blue has weight 0, so a color missing blue stays eligible.",
          "weights": {"red": 1.0, "blue": 0.0},
          "palette": [
            {"id": 5, "responses": {"red": 0.9}}
          ],
          "target": {"red": 0.7, "blue": 0.1},
          "expected": {"selected_color_id": 5, "score": 0.04000000000000001, "tie": false, "excluded_color_ids": []}
        },
        {
          "id": "all-candidates-excluded",
          "description": "Every candidate misses a required measurement; the target goes unmatched.",
          "weights": {"blue": 1.0},
          "palette": [
            {"id": 9, "responses": {"red": 1.0}}
          ],
          "target": {"blue": 0.25},
          "expected": {"selected_color_id": null, "tie": false, "excluded_color_ids": [9]}
        }
      ]
    }
    """
}
