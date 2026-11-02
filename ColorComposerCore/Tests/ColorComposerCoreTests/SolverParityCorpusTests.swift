import XCTest
@testable import ColorComposerCore

/// Consumes the committed solver parity corpus
/// (`Fixtures/solver_parity_corpus.json`) and asserts that
/// `WeightedSquaredErrorScorer` — and the production `CompositionSolver`
/// selection path — reproduce the expected selections exactly, including tie
/// cases (earliest palette entry wins), exclusions (a candidate or target
/// missing a measurement for any required channel is excluded — missing is
/// never zero), and weight handling (zero-weight channels are not required;
/// positive weights scale each channel's squared contribution).
///
/// The corpus mirrors the `ColorMatching.WeightedSquaredError` solver on the
/// server. See `docs/solver-parity-corpus.md` for where the corpus lives and
/// how to refresh it once viamin/color_matching#111 publishes the generated
/// corpus.
final class SolverParityCorpusTests: XCTestCase {
    private struct ParityCandidate: Decodable {
        let id: Int
        let responses: [String: Double]
    }

    private struct ParityExpected: Decodable {
        let selectedId: Int?
        let selectedIndex: Int?
        let excludedIds: [Int]
        let score: Double?
        let tieIds: [Int]?
    }

    private struct ParityCase: Decodable {
        let id: String
        let description: String
        let palette: [ParityCandidate]
        let target: [String: Double]
        let weights: [String: Double]
        let expected: ParityExpected
    }

    private struct ParityCorpus: Decodable {
        let version: Int
        let scorer: String
        let channelOrder: [String]
        let tiePolicy: String
        let cases: [ParityCase]
    }

    private let scorer = WeightedSquaredErrorScorer()

    // MARK: - Corpus loading

    /// Loads the corpus committed next to this test file. SwiftPM only bundles
    /// resources declared in `Package.swift`, so the fixture is located via
    /// `#filePath` — which works identically under `swift test` and Xcode.
    private func loadCorpus() throws -> ParityCorpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver_parity_corpus.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(
                domain: "SolverParityCorpus", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing committed corpus at \(url.path) — see docs/solver-parity-corpus.md"]
            )
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: data)
    }

    // MARK: - Corpus contract

    func testCorpusFileIsCommittedAndWellFormed() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.version, 1, "Unsupported corpus version — update the loader and docs/solver-parity-corpus.md after refreshing the corpus.")
        XCTAssertEqual(corpus.scorer, "weighted_squared_error")
        XCTAssertEqual(corpus.channelOrder, LightingCondition.all.map(\.rawValue), "Corpus channel order must stay the solver's canonical order.")
        XCTAssertEqual(corpus.tiePolicy, "earliest_palette_entry_wins")
        XCTAssertFalse(corpus.cases.isEmpty, "A parity corpus with no cases proves nothing; refresh it from viamin/color_matching#111.")
    }

    func testCorpusContainsTieExclusionAndWeightCases() throws {
        let corpus = try loadCorpus()
        let ids = Set(corpus.cases.map(\.id))

        let tieCases = corpus.cases.filter { $0.expected.tieIds != nil }
        XCTAssertGreaterThanOrEqual(tieCases.count, 2, "Tie coverage is a deliverable of issue #39; expected at least the identical-vector and symmetric-mirror tie cases.")

        XCTAssertTrue(corpus.cases.contains { !$0.expected.excludedIds.isEmpty }, "Exclusion coverage is a deliverable of issue #39.")
        XCTAssertTrue(ids.contains("elixir_doctest_0_205"), "The documented Elixir doctest case must stay in the corpus.")
    }

    /// The doctest corpus case must reproduce the documented Elixir
    /// `WeightedSquaredError` doctest value (0.205).
    func testDoctestCaseScoreMatchesElixirDoctestValue() throws {
        let corpus = try loadCorpus()
        let doctestCase = try XCTUnwrap(corpus.cases.first { $0.id == "elixir_doctest_0_205" })
        let score = try XCTUnwrap(doctestCase.expected.score)
        XCTAssertEqual(score, 0.205, accuracy: 1e-9)
    }

    // MARK: - Parity: scorer-level selections

    func testScorerSelectionsMatchCorpusExactlyIncludingTies() throws {
        let corpus = try loadCorpus()
        for case_ in corpus.cases {
            runCase(case_, solverLevel: false)
        }
    }

    // MARK: - Parity: end-to-end solver selections

    /// The corpus selection must also hold through the production
    /// `CompositionSolver` fast path (1×1 composition per case), so parity is
    /// enforced for what the app actually runs — not just the isolated scorer.
    func testSolverSelectionsMatchCorpusExactly() throws {
        let corpus = try loadCorpus()
        for case_ in corpus.cases where case_.expected.selectedId != nil {
            runCase(case_, solverLevel: true)
        }
    }

    // MARK: - Case runner

    private func runCase(_ case_: ParityCase, solverLevel: Bool) {
        let palette = case_.palette.map { candidate in
            PaletteColor(
                id: candidate.id,
                hex: "#000000",
                rgb: RGBColor(hex: "#000000")!,
                responses: Dictionary(
                    uniqueKeysWithValues: candidate.responses.compactMap { key, value in
                        LightingCondition(rawValue: key).map { ($0, IlluminationResponse(brightness: value)) }
                    }
                )
            )
        }

        let target = TargetResponseVector(Dictionary(
            uniqueKeysWithValues: case_.target.compactMap { key, value in
                LightingCondition(rawValue: key).map { ($0, value) }
            }
        ))

        let weights = ChannelWeights(
            white: case_.weights["white"] ?? 0,
            red: case_.weights["red"] ?? 0,
            green: case_.weights["green"] ?? 0,
            blue: case_.weights["blue"] ?? 0,
            lps: case_.weights["lps"] ?? 0
        )

        // Score every candidate; earliest strictly-lower score wins.
        var excludedIds: [Int] = []
        var bestIndex: Int?
        var bestScore: Double?
        var scoresById: [Int: Double] = [:]
        for (index, color) in palette.enumerated() {
            switch scorer.score(candidate: color, target: target, weights: weights) {
            case .excluded:
                excludedIds.append(color.id)
            case .score(let value):
                scoresById[color.id] = value
                if value < (bestScore ?? .infinity) {
                    bestScore = value
                    bestIndex = index
                }
            }
        }

        let label = "case \(case_.id)"
        XCTAssertEqual(
            Set(excludedIds), Set(case_.expected.excludedIds),
            "\(label): excluded candidates disagree — a missing measurement must exclude, never read as zero brightness"
        )
        XCTAssertEqual(bestIndex, case_.expected.selectedIndex, "\(label): selected palette index disagrees")
        if let selected = case_.expected.selectedId {
            XCTAssertEqual(bestIndex.map({ palette[$0].id }), selected, "\(label): selected color id disagrees")
        } else {
            XCTAssertNil(bestIndex, "\(label): expected no eligible candidate, but one was selected")
        }

        if let expectedScore = case_.expected.score, let bestScore {
            XCTAssertEqual(bestScore, expectedScore, accuracy: 1e-12, "\(label): winning score disagrees")
        }

        // Ties must be exact ties, and the earliest palette entry must win them.
        if let tieIds = case_.expected.tieIds {
            XCTAssertEqual(tieIds.count, 2, "\(label): tie assertions cover pairs; extend the runner for larger ties")
            let tieScores = tieIds.compactMap { scoresById[$0] }
            XCTAssertEqual(tieScores.count, tieIds.count, "\(label): tied candidates must be eligible (scored, not excluded)")
            if tieScores.count == 2 {
                XCTAssertEqual(tieScores[0], tieScores[1], "\(label): expected an exact tie between \(tieIds)")
            }
            let tiedIndexes = tieIds.compactMap { id in palette.firstIndex { $0.id == id } }
            XCTAssertEqual(tiedIndexes.count, tieIds.count, "\(label): tie ids must exist in the palette")
            if let winner = case_.expected.selectedId,
               let winnerIndex = palette.firstIndex(where: { $0.id == winner }),
               let earliest = tiedIndexes.min() {
                XCTAssertEqual(winnerIndex, earliest, "\(label): ties must resolve to the earliest palette entry")
            }
        }

        if solverLevel {
            runSolverLevel(case_: case_, palette: palette, target: target, weights: weights)
        }
    }

    private func runSolverLevel(
        case_: ParityCase,
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) {
        var sourceGrids: [LightingCondition: BrightnessGrid] = [:]
        for (condition, _) in weights.activeEntries {
            guard let value = target.value(for: condition) else {
                return XCTFail("case \(case_.id): corpus target lacks an active condition required for the solver run")
            }
            sourceGrids[condition] = BrightnessGrid(width: 1, height: 1, values: [value])
        }

        let result: CompositionResult
        do {
            result = try CompositionSolver(scorer: WeightedSquaredErrorScorer())
                .solve(palette: palette, sourceGrids: sourceGrids, weights: weights)
        } catch {
            return XCTFail("case \(case_.id): solver threw \(error) for a case with an expected selection")
        }

        let label = "case \(case_.id) (solver)"
        XCTAssertEqual(result.colorIndex(x: 0, y: 0), case_.expected.selectedIndex, "\(label): solved selection disagrees")
        XCTAssertEqual(result.unmatchedCellCount, 0, "\(label): expected a matched cell")
        if let expectedScore = case_.expected.score {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedScore, accuracy: 1e-12, "\(label): solved error disagrees")
        }
    }
}
