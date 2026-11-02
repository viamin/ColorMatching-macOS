import Foundation
import XCTest
@testable import ColorComposerCore

/// Solver parity against the committed `color_matching` corpus (#39).
///
/// `Fixtures/weighted_squared_error_corpus.json` mirrors the
/// `WeightedSquaredError` parity corpus published by the `color_matching`
/// service (viamin/color_matching#111). Each case carries the Elixir
/// solver's expected selection; these tests replay every case through
/// `WeightedSquaredErrorScorer` — and through the full `CompositionSolver`
/// fast path — and require the selections to match exactly, including tie
/// cases (earliest candidate wins, mirroring
/// `IlluminantMatching.best_match/4`), exclusions, and weight handling.
///
/// See `docs/parity-corpus.md` for the corpus schema and refresh procedure.
///
/// Deliberately larger than the ~100-line guideline: the corpus wire shape,
/// its solver-domain conversion, and the parity assertions share one schema
/// contract that would only spread if split across collaborators.
final class SolverParityCorpusTests: XCTestCase {
    // MARK: - Corpus wire shape

    /// Raw snake_case wire shape of the corpus document. Unknown JSON keys
    /// are ignored; unknown *light-source* keys are rejected at conversion.
    private struct ParityCorpus: Codable {
        let version: Int
        let source: Source
        let cases: [Case]

        struct Source: Codable {
            let repository: String
            let pullRequest: Int?
            let generator: String
        }

        enum Kind: String, Codable {
            case selection
            case tie
            case exclusion
            case weighting
        }

        struct Case: Codable {
            let id: String
            let kind: Kind
            let description: String
            let weights: [String: Double]
            let target: [String: Double]
            let palette: [PaletteEntry]
            let expected: Expectation
        }

        struct PaletteEntry: Codable {
            let id: Int
            let hex: String
            let responses: [String: Response]
        }

        struct Response: Codable {
            let brightness: Double
        }

        struct Expectation: Codable {
            let selectedColorId: Int?
            let score: Double?
            let excludedColorIds: [Int]?
        }
    }

    private enum CorpusError: Error, LocalizedError {
        case missingFixture(String)
        case unknownLightSource(key: String, caseID: String)
        case unparsableHex(hex: String, caseID: String)

        var errorDescription: String? {
            switch self {
            case .missingFixture(let path):
                return "Parity corpus fixture is missing at \(path). See docs/parity-corpus.md."
            case .unknownLightSource(let key, let caseID):
                return "Corpus case \(caseID) uses light source \"\(key)\", which is not a canonical condition."
            case .unparsableHex(let hex, let caseID):
                return "Corpus case \(caseID) has palette hex \"\(hex)\", which does not parse."
            }
        }
    }

    /// The corpus converted to solver-domain values.
    private struct LoadedCorpus {
        struct LoadedCase {
            let id: String
            let kind: ParityCorpus.Kind
            let weights: ChannelWeights
            let target: TargetResponseVector
            let palette: [PaletteColor]
            let expected: ParityCorpus.Expectation
        }

        let version: Int
        let cases: [LoadedCase]
    }

    // MARK: - Corpus loading

    /// Resolves the fixture relative to this source file, so no SwiftPM
    /// resource bundle is needed and the suite runs identically from
    /// `swift test` and the `bin/lint` harness.
    private static func fixtureURL() throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_corpus.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CorpusError.missingFixture(url.path)
        }
        return url
    }

    private static func loadCorpus() throws -> LoadedCorpus {
        let data = try Data(contentsOf: fixtureURL())
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let raw = try decoder.decode(ParityCorpus.self, from: data)
        return LoadedCorpus(version: raw.version, cases: try raw.cases.map(loadCase))
    }

    private static func loadCase(_ raw: ParityCorpus.Case) throws -> LoadedCorpus.LoadedCase {
        LoadedCorpus.LoadedCase(
            id: raw.id,
            kind: raw.kind,
            weights: try makeChannelWeights(raw.weights, caseID: raw.id),
            target: try makeTargetVector(raw.target, caseID: raw.id),
            palette: try makePalette(raw.palette, caseID: raw.id),
            expected: raw.expected
        )
    }

    private static func condition(for key: String, caseID: String) throws -> LightingCondition {
        guard let condition = LightingCondition(rawValue: key) else {
            throw CorpusError.unknownLightSource(key: key, caseID: caseID)
        }
        return condition
    }

    private static func makeChannelWeights(_ raw: [String: Double], caseID: String) throws -> ChannelWeights {
        var weights = ChannelWeights()
        for (key, value) in raw {
            switch try condition(for: key, caseID: caseID) {
            case .white: weights.white = value
            case .red: weights.red = value
            case .green: weights.green = value
            case .blue: weights.blue = value
            case .lps: weights.lps = value
            }
        }
        return weights
    }

    private static func makeTargetVector(_ raw: [String: Double], caseID: String) throws -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in raw {
            brightness[try condition(for: key, caseID: caseID)] = value
        }
        return TargetResponseVector(brightness)
    }

    private static func makePalette(_ raw: [ParityCorpus.PaletteEntry], caseID: String) throws -> [PaletteColor] {
        try raw.map { entry in
            guard let rgb = RGBColor(hex: entry.hex) else {
                throw CorpusError.unparsableHex(hex: entry.hex, caseID: caseID)
            }
            var responses: [LightingCondition: IlluminationResponse] = [:]
            for (key, response) in entry.responses {
                responses[try condition(for: key, caseID: caseID)] =
                    IlluminationResponse(brightness: response.brightness)
            }
            return PaletteColor(id: entry.id, hex: entry.hex, rgb: rgb, responses: responses)
        }
    }

    // MARK: - Selection policy under test

    private struct SelectionOutcome {
        let winnerID: Int?
        let winningScore: Double?
        /// IDs of every candidate scoring exactly the winning score, in
        /// palette order. More than one element proves a genuine tie.
        let tiedWinnerIDs: [Int]
        let excludedIDs: [Int]
    }

    /// Applies the `color_matching` selection policy: the lowest score wins,
    /// and the earliest candidate wins a tie (mirroring
    /// `IlluminantMatching.best_match/4`).
    private static func bestMatch(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> SelectionOutcome {
        let scorer = WeightedSquaredErrorScorer()
        var scores: [(id: Int, score: Double)] = []
        var excludedIDs: [Int] = []

        for color in palette {
            switch scorer.score(candidate: color, target: target, weights: weights) {
            case .excluded:
                excludedIDs.append(color.id)
            case .score(let value):
                scores.append((color.id, value))
            }
        }

        var winnerID: Int?
        var winningScore: Double?
        for candidate in scores {
            if let current = winningScore, candidate.score >= current { continue }
            winningScore = candidate.score
            winnerID = candidate.id
        }

        let tiedWinnerIDs = winningScore.map { winning in
            scores.filter { $0.score == winning }.map(\.id)
        } ?? []

        return SelectionOutcome(
            winnerID: winnerID,
            winningScore: winningScore,
            tiedWinnerIDs: tiedWinnerIDs,
            excludedIDs: excludedIDs
        )
    }

    // MARK: - Corpus integrity

    func testCorpusMeetsIntegrityBar() throws {
        let corpus = try Self.loadCorpus()

        XCTAssertEqual(corpus.version, 1)
        XCTAssertGreaterThanOrEqual(corpus.cases.count, 10, "corpus must keep at least ten cases")

        let ids = corpus.cases.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "case ids must be unique")

        XCTAssertGreaterThanOrEqual(corpus.cases.filter { $0.kind == .tie }.count, 2, "corpus must keep tie cases")
        XCTAssertGreaterThanOrEqual(
            corpus.cases.filter { $0.kind == .exclusion }.count,
            2,
            "corpus must keep exclusion cases"
        )

        for testCase in corpus.cases {
            XCTAssertFalse(testCase.palette.isEmpty, "case \(testCase.id): palette must not be empty")
            XCTAssertFalse(
                testCase.weights.activeConditions.isEmpty,
                "case \(testCase.id): at least one weight must be positive"
            )
        }
    }

    // MARK: - Parity

    /// The core parity assertion: every corpus case's selection — including
    /// score and exclusions — must match the recorded expectation exactly.
    func testSelectionsMatchExpectedOutputsExactly() throws {
        let corpus = try Self.loadCorpus()

        for testCase in corpus.cases {
            let outcome = Self.bestMatch(palette: testCase.palette, target: testCase.target, weights: testCase.weights)

            XCTAssertEqual(
                outcome.winnerID,
                testCase.expected.selectedColorId,
                "case \(testCase.id): selection mismatch"
            )

            if let excludedIDs = testCase.expected.excludedColorIds {
                XCTAssertEqual(outcome.excludedIDs, excludedIDs, "case \(testCase.id): exclusion mismatch")
            }
            if let expectedScore = testCase.expected.score {
                let score = try XCTUnwrap(outcome.winningScore, "case \(testCase.id): expected a rankable winner")
                XCTAssertEqual(score, expectedScore, accuracy: 1e-9, "case \(testCase.id): score mismatch")
            }
        }
    }

    /// Tie cases must be genuine bitwise ties, and the earliest tied
    /// candidate must win — the documented `best_match/4` policy.
    func testTieCasesSelectTheEarliestTiedCandidate() throws {
        let corpus = try Self.loadCorpus()
        let tieCases = corpus.cases.filter { $0.kind == .tie }
        XCTAssertGreaterThanOrEqual(tieCases.count, 2)

        for testCase in tieCases {
            let outcome = Self.bestMatch(palette: testCase.palette, target: testCase.target, weights: testCase.weights)
            let expectedID = try XCTUnwrap(
                testCase.expected.selectedColorId,
                "case \(testCase.id): tie cases record an expected winner"
            )

            XCTAssertGreaterThanOrEqual(outcome.tiedWinnerIDs.count, 2, "case \(testCase.id): expected a genuine tie")
            XCTAssertEqual(
                outcome.tiedWinnerIDs.first,
                expectedID,
                "case \(testCase.id): earliest tied candidate must win"
            )
            XCTAssertEqual(outcome.winnerID, expectedID, "case \(testCase.id): selection mismatch")
        }
    }

    /// A candidate missing a measurement for any weight-positive condition
    /// is excluded — never scored as if the channel were zero brightness.
    func testExclusionCasesNeverScoreMissingMeasurements() throws {
        let corpus = try Self.loadCorpus()
        let exclusionCases = corpus.cases.filter { $0.kind == .exclusion }
        XCTAssertGreaterThanOrEqual(exclusionCases.count, 2)

        for testCase in exclusionCases {
            let outcome = Self.bestMatch(palette: testCase.palette, target: testCase.target, weights: testCase.weights)

            if testCase.expected.selectedColorId == nil {
                XCTAssertNil(outcome.winnerID, "case \(testCase.id): every candidate must be excluded")
                XCTAssertEqual(
                    Set(outcome.excludedIDs),
                    Set(testCase.palette.map(\.id)),
                    "case \(testCase.id): the whole palette must be excluded"
                )
            } else {
                XCTAssertFalse(
                    outcome.excludedIDs.isEmpty,
                    "case \(testCase.id): expected at least one excluded candidate"
                )
            }
        }
    }

    /// Channels with weight 0 neither require a measurement nor contribute
    /// to the score — the winner may legitimately lack one.
    func testZeroWeightChannelsNeitherRequireNorScore() throws {
        let corpus = try Self.loadCorpus()
        let weightingCases = corpus.cases.filter { $0.kind == .weighting }
        XCTAssertFalse(weightingCases.isEmpty)

        for testCase in weightingCases {
            let outcome = Self.bestMatch(palette: testCase.palette, target: testCase.target, weights: testCase.weights)
            let winnerID = try XCTUnwrap(outcome.winnerID, "case \(testCase.id)")
            let winner = try XCTUnwrap(testCase.palette.first { $0.id == winnerID }, "case \(testCase.id)")

            let missingInactive = LightingCondition.all.filter {
                testCase.weights.weight(for: $0) == 0 && winner.brightness(for: $0) == nil
            }
            XCTAssertFalse(
                missingInactive.isEmpty,
                "case \(testCase.id): winner must lack a measurement on a zero-weight channel"
            )
        }
    }

    // MARK: - Solver fast path

    /// The full `CompositionSolver` (default-scorer fast path) must reproduce
    /// every solvable corpus selection, its recorded error, and its exclusion
    /// count on a 1×1 grid.
    func testCompositionSolverReproducesEverySolvableSelection() throws {
        let corpus = try Self.loadCorpus()

        var solvable: [LoadedCorpus.LoadedCase] = []
        var unsolvable: [LoadedCorpus.LoadedCase] = []
        for testCase in corpus.cases {
            if isSolvable(testCase) {
                solvable.append(testCase)
            } else {
                unsolvable.append(testCase)
            }
        }

        XCTAssertFalse(unsolvable.isEmpty, "corpus keeps the target-gap exclusion probe")
        XCTAssertTrue(
            unsolvable.allSatisfy { $0.expected.selectedColorId == nil },
            "only all-excluded cases may be unsolvable end-to-end"
        )

        for testCase in solvable {
            let expectedID = try XCTUnwrap(testCase.expected.selectedColorId, "case \(testCase.id)")
            let expectedIndex = try XCTUnwrap(testCase.palette.firstIndex { $0.id == expectedID })

            let result = try CompositionSolver().solve(
                palette: testCase.palette,
                sourceGrids: try sourceGrids(for: testCase),
                weights: testCase.weights
            )

            XCTAssertEqual(result.colorIndex(x: 0, y: 0), expectedIndex, "case \(testCase.id): solver selection mismatch")
            if let excludedIDs = testCase.expected.excludedColorIds {
                XCTAssertEqual(
                    result.excludedCandidateCount,
                    excludedIDs.count,
                    "case \(testCase.id): solver exclusion count mismatch"
                )
            }
            if let expectedScore = testCase.expected.score {
                XCTAssertEqual(
                    result.error(x: 0, y: 0),
                    expectedScore,
                    accuracy: 1e-9,
                    "case \(testCase.id): solver error mismatch"
                )
            }
        }
    }

    /// A case is solvable end-to-end when the target carries a value for
    /// every weight-positive condition. The app always has a source image
    /// per active channel; only the deliberate target-gap exclusion probe
    /// lacks one.
    private func isSolvable(_ testCase: LoadedCorpus.LoadedCase) -> Bool {
        testCase.weights.activeConditions.allSatisfy { testCase.target.value(for: $0) != nil }
    }

    private func sourceGrids(for testCase: LoadedCorpus.LoadedCase) throws -> [LightingCondition: BrightnessGrid] {
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for condition in testCase.weights.activeConditions {
            let value = try XCTUnwrap(
                testCase.target.value(for: condition),
                "case \(testCase.id): no target value for active \(condition)"
            )
            grids[condition] = BrightnessGrid(width: 1, height: 1, values: [value])
        }
        return grids
    }
}
