import XCTest
@testable import ColorComposerCore

/// Solver parity against the committed `color_matching` corpus (upstream
/// viamin/color_matching#111).
///
/// The corpus pins the selection semantics this app deliberately mirrors from
/// the Elixir `WeightedSquaredError` solver:
///
/// - score = Σ over active conditions of `weight × (candidate − target)²`
///   (`ChannelWeights` entries `> 0` are active, `0` or absent are ignored),
/// - a candidate missing a measurement for *any* active condition — or a
///   target missing one — is **excluded**, never scored as zero brightness,
/// - selection is the lowest-scoring eligible candidate, with exact ties
///   resolving to the **earliest candidate in palette order** (matching
///   `CompositionSolver`'s deterministic tie-breaking).
///
/// The corpus lives at
/// `Tests/ColorComposerCoreTests/Fixtures/weighted_squared_error_parity_corpus.json`.
/// Set `SOLVER_PARITY_CORPUS_PATH` to run the same assertions against a
/// freshly exported upstream corpus before committing it (see
/// `docs/solver-parity-corpus.md`).
final class SolverParityCorpusTests: XCTestCase {
    private static var corpusURL: URL {
        if let override = ProcessInfo.processInfo.environment["SOLVER_PARITY_CORPUS_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("weighted_squared_error_parity_corpus.json")
    }

    private func loadCorpus(file: StaticString = #filePath, line: UInt = #line) throws -> ParityCorpus {
        let url = Self.corpusURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Parity corpus not found at \(url.path)", file: file, line: line)
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(ParityCorpus.self, from: data)
        } catch {
            XCTFail("Parity corpus at \(url.path) does not decode: \(error)", file: file, line: line)
            throw error
        }
    }

    // MARK: - Corpus hygiene

    /// The committed fixture must exist at its documented location so the
    /// parity suite cannot silently degrade to a skip.
    func testDefaultCorpusFixtureExistsAtCommittedLocation() {
        XCTAssertFalse(
            ProcessInfo.processInfo.environment.keys.contains("SOLVER_PARITY_CORPUS_PATH"),
            "Unset SOLVER_PARITY_CORPUS_PATH to verify the committed fixture location"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: Self.corpusURL.path),
            "Expected the committed corpus at \(Self.corpusURL.path)"
        )
    }

    /// Guards against a stub corpus: the committed fixture must decode and
    /// cover every scenario class the parity contract calls out — ties,
    /// exclusions, zero-weight handling, and a no-selection case.
    func testCorpusDecodesAndCoversRequiredScenarios() throws {
        let corpus = try loadCorpus()

        XCTAssertGreaterThanOrEqual(corpus.cases.count, 8, "Corpus is suspiciously small")
        XCTAssertGreaterThanOrEqual(corpus.cases.filter { $0.expected.tie == true }.count, 2,
                                    "Corpus must include tie cases")
        XCTAssertGreaterThanOrEqual(
            corpus.cases.filter { !($0.expected.excludedCandidateIds ?? []).isEmpty }.count, 2,
            "Corpus must include exclusion cases"
        )
        XCTAssertGreaterThanOrEqual(corpus.cases.filter { $0.expected.selectedCandidateId == nil }.count, 1,
                                    "Corpus must include a case where every candidate is excluded")
        XCTAssertGreaterThanOrEqual(corpus.cases.filter { $0.hasExplicitZeroWeight }.count, 1,
                                    "Corpus must pin zero-weight (inactive channel) handling")

        for testCase in corpus.cases {
            XCTAssertFalse(testCase.candidates.isEmpty, "Case \(testCase.id) has no candidates")
            XCTAssertEqual(
                Set(testCase.candidates.map(\.id)).count, testCase.candidates.count,
                "Case \(testCase.id) has duplicate candidate ids"
            )
            if testCase.expected.tie == true {
                XCTAssertGreaterThanOrEqual((testCase.expected.tiedCandidateIds ?? []).count, 2,
                                            "Tie case \(testCase.id) must list the tied candidates")
            }
            if testCase.expected.selectedCandidateId != nil {
                XCTAssertNotNil(testCase.expected.score,
                                "Case \(testCase.id) expects a selection and must pin its score")
            }
        }
    }

    // MARK: - Selection parity

    /// The core parity assertion: for every corpus case, the candidate chosen
    /// by scoring with `WeightedSquaredErrorScorer` (mirroring the solver's
    /// strict less-than, earliest-wins scan) must equal the corpus selection
    /// exactly — including tie and no-selection cases — and the winning score
    /// must match when pinned.
    func testScorerSelectionsMatchCorpusExactly() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for testCase in corpus.cases {
            let weights = try testCase.channelWeights()
            let target = try testCase.targetVector()
            let palette = try testCase.paletteColors()
            let selected = Self.select(scorer: scorer, candidates: palette, target: target, weights: weights)

            guard let expectedID = testCase.expected.selectedCandidateId else {
                XCTAssertNil(selected, "Case \(testCase.id): expected no eligible candidate, selected \(String(describing: selected?.id))")
                continue
            }

            let chosen = try XCTUnwrap(selected, "Case \(testCase.id): expected candidate \(expectedID), got no eligible candidate")
            XCTAssertEqual(chosen.id, expectedID,
                           "Case \(testCase.id): selection mismatch (score \(chosen.score))")
            if let expectedScore = testCase.expected.score {
                XCTAssertEqual(chosen.score, expectedScore, accuracy: 1e-9,
                               "Case \(testCase.id): winning score mismatch")
            }
        }
    }

    /// Tie cases: every listed tied candidate must reach the same minimum
    /// score, and the winner must be the tied candidate that appears earliest
    /// in palette (candidate array) order — not the lowest id.
    func testTieCasesSelectEarliestTiedCandidateInPaletteOrder() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        let tieCases = corpus.cases.filter { $0.expected.tie == true }
        XCTAssertGreaterThanOrEqual(tieCases.count, 2, "Corpus must exercise ties")

        for testCase in tieCases {
            let weights = try testCase.channelWeights()
            let target = try testCase.targetVector()
            let palette = try testCase.paletteColors()
            let scores = Self.scoredCandidates(scorer: scorer, candidates: palette, target: target, weights: weights)
            let tiedIDs = try XCTUnwrap(testCase.expected.tiedCandidateIds, "Tie case \(testCase.id) lists no tied candidates")

            let tiedScores = try tiedIDs.map { id -> Double in
                let entry = try XCTUnwrap(scores.first(where: { $0.id == id }),
                                          "Case \(testCase.id): tied id \(id) is not an eligible candidate")
                return entry.score
            }
            for score in tiedScores.dropFirst() {
                XCTAssertEqual(score, tiedScores[0], accuracy: 1e-12,
                               "Case \(testCase.id): tied candidates do not share the same score")
            }

            let earliestTiedID = try XCTUnwrap(
                palette.map(\.id).first(where: tiedIDs.contains),
                "Case \(testCase.id): no tied candidate appears in the palette"
            )
            XCTAssertEqual(testCase.expected.selectedCandidateId, earliestTiedID,
                           "Case \(testCase.id): tie must resolve to the earliest candidate in palette order")
        }
    }

    /// Exclusion parity: candidates the corpus marks excluded must come back
    /// `.excluded` from the scorer — a missing required measurement must
    /// disqualify a candidate even when it would otherwise win.
    func testCorpusExcludedCandidatesAreExcludedAndNeverSelected() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for testCase in corpus.cases {
            let excludedIDs = testCase.expected.excludedCandidateIds ?? []
            guard !excludedIDs.isEmpty else { continue }

            let weights = try testCase.channelWeights()
            let target = try testCase.targetVector()
            let palette = try testCase.paletteColors()
            let byID = Dictionary(palette.map({ ($0.id, $0) }), uniquingKeysWith: { first, _ in first })

            for id in excludedIDs {
                let candidate = try XCTUnwrap(byID[id], "Case \(testCase.id): excluded id \(id) is not a candidate")
                XCTAssertEqual(
                    scorer.score(candidate: candidate, target: target, weights: weights),
                    .excluded,
                    "Case \(testCase.id): candidate \(id) must be excluded (missing a required measurement)"
                )
            }

            let selected = Self.select(scorer: scorer, candidates: palette, target: target, weights: weights)
            if let selected {
                XCTAssertFalse(excludedIDs.contains(selected.id),
                               "Case \(testCase.id): excluded candidate \(selected.id) was selected")
            }
        }
    }

    /// The corpus selections must also hold through the real
    /// `CompositionSolver` path (its optimized fast path implements the same
    /// earliest-wins scan): solving a 1×1 grid per case must land on the same
    /// palette color, score, and excluded-candidate count.
    ///
    /// Cases whose target vector itself lacks an active condition cannot be
    /// expressed as source grids (every grid cell has a value by definition)
    /// and are skipped here; the scorer-level tests still cover them.
    func testCorpusSelectionsAgreeWithCompositionSolver() throws {
        let corpus = try loadCorpus()
        let solverCases = try corpus.cases.filter { testCase in
            let weights = try testCase.channelWeights()
            let target = try testCase.targetVector()
            return weights.activeConditions.allSatisfy { target.value(for: $0) != nil }
        }
        XCTAssertGreaterThanOrEqual(solverCases.count, 6,
                                    "Most corpus cases should be expressible as 1×1 solves")

        for testCase in solverCases {
            let weights = try testCase.channelWeights()
            let target = try testCase.targetVector()
            let palette = try testCase.paletteColors()

            var grids: [LightingCondition: BrightnessGrid] = [:]
            for condition in weights.activeConditions {
                grids[condition] = BrightnessGrid(width: 1, height: 1, fill: target.value(for: condition) ?? 0)
            }

            let result = try CompositionSolver(scorer: WeightedSquaredErrorScorer())
                .solve(palette: palette, sourceGrids: grids, weights: weights)

            let index = result.colorIndex(x: 0, y: 0)
            if let expectedID = testCase.expected.selectedCandidateId {
                let indexForID = try XCTUnwrap(palette.firstIndex(where: { $0.id == expectedID }),
                                               "Case \(testCase.id): expected id \(expectedID) not in palette")
                XCTAssertEqual(index, indexForID, "Case \(testCase.id): solver picked a different palette entry")
                XCTAssertEqual(result.error(x: 0, y: 0), testCase.expected.score ?? 0, accuracy: 1e-9,
                               "Case \(testCase.id): solver winning score mismatch")
            } else {
                XCTAssertNil(index, "Case \(testCase.id): expected the solver to leave the cell unmatched")
            }

            if let excluded = testCase.expected.excludedCandidateIds {
                XCTAssertEqual(result.excludedCandidateCount, excluded.count,
                               "Case \(testCase.id): solver excluded-candidate count mismatch")
            }
        }
    }

    // MARK: - Selection (mirrors the solver's scan)

    private struct ScoredCandidate {
        let id: Int
        let score: Double
    }

    /// Strictly-less-than scan over candidates in palette order — the same
    /// rule as `CompositionSolver`'s fast path, so exact ties keep the
    /// earliest candidate.
    private static func select(
        scorer: WeightedSquaredErrorScorer,
        candidates: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> ScoredCandidate? {
        scoredCandidates(scorer: scorer, candidates: candidates, target: target, weights: weights)
            .min { $0.score < $1.score }
    }

    private static func scoredCandidates(
        scorer: WeightedSquaredErrorScorer,
        candidates: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> [ScoredCandidate] {
        candidates.compactMap { color in
            guard case .score(let value) = scorer.score(candidate: color, target: target, weights: weights) else {
                return nil
            }
            return ScoredCandidate(id: color.id, score: value)
        }
    }
}

// MARK: - Corpus wire format

private struct ParityCorpus: Codable {
    let schema: Int
    let cases: [ParityCase]
}

private struct ParityCase: Codable {
    struct Weights: Codable {
        let white: Double?
        let red: Double?
        let green: Double?
        let blue: Double?
        let lps: Double?
    }

    struct Candidate: Codable {
        struct Response: Codable {
            let brightness: Double
        }

        let id: Int
        let name: String?
        let hex: String
        let responses: [String: Response]
    }

    struct Expected: Codable {
        let selectedCandidateId: Int?
        let score: Double?
        let tie: Bool?
        let tiedCandidateIds: [Int]?
        let excludedCandidateIds: [Int]?
    }

    let id: String
    let description: String?
    let weights: Weights
    let target: [String: Double]
    let candidates: [Candidate]
    let expected: Expected

    var hasExplicitZeroWeight: Bool {
        [weights.white, weights.red, weights.green, weights.blue, weights.lps]
            .contains { $0 == 0 }
    }

    func channelWeights() throws -> ChannelWeights {
        ChannelWeights(
            white: weights.white ?? 0,
            red: weights.red ?? 0,
            green: weights.green ?? 0,
            blue: weights.blue ?? 0,
            lps: weights.lps ?? 0
        )
    }

    func targetVector() throws -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in target {
            let condition = try ParityCase.condition(key)
            brightness[condition] = value
        }
        return TargetResponseVector(brightness)
    }

    func paletteColors() throws -> [PaletteColor] {
        try candidates.map { candidate in
            var responses: [LightingCondition: IlluminationResponse] = [:]
            for (key, response) in candidate.responses {
                responses[try ParityCase.condition(key)] = IlluminationResponse(brightness: response.brightness)
            }
            guard let rgb = RGBColor(hex: candidate.hex) else {
                throw NSError(domain: "SolverParityCorpus", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Case \(id): candidate \(candidate.id) has unparseable hex \(candidate.hex)"])
            }
            return PaletteColor(
                id: candidate.id,
                name: candidate.name,
                hex: candidate.hex,
                rgb: rgb,
                responses: responses
            )
        }
    }

    private static func condition(_ key: String) throws -> LightingCondition {
        guard let condition = LightingCondition(rawValue: key) else {
            throw NSError(domain: "SolverParityCorpus", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown light source key \(key) in corpus"])
        }
        return condition
    }
}
