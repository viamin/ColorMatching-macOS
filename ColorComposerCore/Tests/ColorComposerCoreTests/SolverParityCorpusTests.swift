import XCTest
@testable import ColorComposerCore

// MARK: - Corpus model (wire format vendored from viamin/color_matching#111)

/// The committed solver-parity corpus document.
///
/// Wire format (snake_case JSON; see `docs/solver-parity-corpus.md`):
/// `{ "version": 1, "source": "...", "cases": [ ... ] }`.
struct ParityCorpus: Codable {
    struct Candidate: Codable {
        let id: Int
        let name: String?
        let hex: String
        /// Measured brightness per canonical light-source key.
        let responses: [String: Double]
    }

    struct Case: Codable {
        let id: String
        let description: String?
        let palette: [Candidate]
        /// Target brightness per light-source key; must cover every condition
        /// with a positive weight.
        let target: [String: Double]
        /// Channel weights per light-source key; keys with weight 0 are inert.
        let weights: [String: Double]
        /// The Elixir `IlluminantMatching.best_match/4` selection, or `null`
        /// when every candidate is excluded.
        let expectedSelectedId: Int?
        /// The Elixir `WeightedSquaredError` score of the winner, when recorded.
        let expectedScore: Double?
        /// Every candidate id achieving the minimum score, when the case is a
        /// tie. The client must select the earliest one in palette order.
        let tieCandidateIds: [Int]?
        /// Every candidate id excluded for a missing required measurement.
        let excludedCandidateIds: [Int]?
    }

    let version: Int
    let source: String?
    let cases: [Case]
}

// MARK: - Tests

/// Solver-parity corpus consumption (issue #39).
///
/// Loads the corpus committed at
/// `Tests/ColorComposerCoreTests/Fixtures/solver_parity_corpus.json`
/// (vendored from viamin/color_matching#111) and asserts that
/// `WeightedSquaredErrorScorer` scores and `CompositionSolver` selections
/// match the Elixir `WeightedSquaredError` / `IlluminantMatching.best_match/4`
/// expected outputs exactly — including ties (earliest palette-order
/// candidate wins) and exclusions (missing measurements, never zero).
///
/// Corpus format and refresh instructions: `docs/solver-parity-corpus.md`.
final class SolverParityCorpusTests: XCTestCase {
    /// Canonical corpus location, resolved from this source file so no
    /// SwiftPM resource declaration is required to find it.
    static let corpusURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/solver_parity_corpus.json")

    private static let scoreAccuracy = 1e-9

    // MARK: Corpus consumption

    func testCorpusIsCommittedAtTheCanonicalLocation() {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: Self.corpusURL.path),
            "Solver parity corpus is missing at \(Self.corpusURL.path). "
                + "Vendor it from viamin/color_matching#111 and commit it there "
                + "(see docs/solver-parity-corpus.md)."
        )
    }

    func testEveryCorpusCaseMatchesTheElixirSelectionExactly() throws {
        let corpus = try loadCorpus()
        XCTAssertFalse(corpus.cases.isEmpty, "The parity corpus must contain at least one case")
        for parityCase in corpus.cases {
            verify(parityCase)
        }
    }

    // MARK: Harness self-check

    /// Runs the documented reference case through the exact same verification
    /// path as the corpus, so a corpus failure means solver divergence, not a
    /// broken harness. The case mirrors the Elixir `WeightedSquaredError`
    /// doctest vector (expected score 0.205) extended with a tied duplicate,
    /// a farther candidate, and an excluded one.
    func testHarnessVerifiesTheDocumentedReferenceCase() throws {
        let corpus = try decodeCorpus(from: Data(Self.referenceCorpusJSON.utf8))
        XCTAssertEqual(corpus.cases.count, 1)
        verify(corpus.cases[0])
    }

    // MARK: Loading

    private struct CorpusMissingError: Error {}

    private func loadCorpus(file: StaticString = #filePath, line: UInt = #line) throws -> ParityCorpus {
        let path = Self.corpusURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            XCTFail(
                "Solver parity corpus not committed at \(path) — vendor it from "
                    + "viamin/color_matching#111 (see docs/solver-parity-corpus.md)",
                file: file, line: line
            )
            throw CorpusMissingError()
        }
        return try decodeCorpus(from: Data(contentsOf: Self.corpusURL), file: file, line: line)
    }

    private func decodeCorpus(from data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> ParityCorpus {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(ParityCorpus.self, from: data)
        } catch {
            XCTFail("Solver parity corpus failed to decode: \(error)", file: file, line: line)
            throw error
        }
    }

    // MARK: Verification

    private func verify(_ parityCase: ParityCorpus.Case, file: StaticString = #filePath, line: UInt = #line) {
        guard let weights = makeWeights(parityCase.weights, caseID: parityCase.id, file: file, line: line),
              let palette = makePalette(parityCase.palette, caseID: parityCase.id, file: file, line: line),
              let target = makeTarget(parityCase, weights: weights, file: file, line: line),
              let grids = makeGrids(for: parityCase, weights: weights, file: file, line: line)
        else { return }

        verifyScorerOutcomes(parityCase, palette: palette, target: target, weights: weights, file: file, line: line)
        verifySolverSelection(parityCase, palette: palette, grids: grids, weights: weights, file: file, line: line)
    }

    private func makeWeights(
        _ raw: [String: Double],
        caseID: String,
        file: StaticString,
        line: UInt
    ) -> ChannelWeights? {
        guard validateKeys(raw.keys, kind: "weights", caseID: caseID, file: file, line: line) else { return nil }
        var weights = ChannelWeights()
        for (key, value) in raw {
            weights[condition: LightingCondition(rawValue: key)!] = value
        }
        guard !weights.activeEntries.isEmpty else {
            XCTFail("Case \(caseID): at least one channel weight must be positive", file: file, line: line)
            return nil
        }
        return weights
    }

    private func makePalette(
        _ raw: [ParityCorpus.Candidate],
        caseID: String,
        file: StaticString,
        line: UInt
    ) -> [PaletteColor]? {
        guard !raw.isEmpty else {
            XCTFail("Case \(caseID): the palette must not be empty", file: file, line: line)
            return nil
        }
        var colors: [PaletteColor] = []
        for candidate in raw {
            guard let rgb = RGBColor(hex: candidate.hex) else {
                XCTFail("Case \(caseID): candidate \(candidate.id) has unparseable hex \"\(candidate.hex)\"", file: file, line: line)
                return nil
            }
            guard validateKeys(candidate.responses.keys, kind: "responses", caseID: caseID, file: file, line: line) else { return nil }
            let responses = Dictionary(
                uniqueKeysWithValues: candidate.responses.map { key, brightness in
                    (LightingCondition(rawValue: key)!, IlluminationResponse(brightness: brightness))
                }
            )
            colors.append(PaletteColor(
                id: candidate.id, name: candidate.name, hex: candidate.hex,
                rgb: rgb, responses: responses
            ))
        }
        return colors
    }

    private func makeTarget(
        _ parityCase: ParityCorpus.Case,
        weights: ChannelWeights,
        file: StaticString,
        line: UInt
    ) -> TargetResponseVector? {
        guard validateKeys(parityCase.target.keys, kind: "target", caseID: parityCase.id, file: file, line: line) else { return nil }
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in parityCase.target {
            brightness[LightingCondition(rawValue: key)!] = value
        }
        for (condition, _) in weights.activeEntries where brightness[condition] == nil {
            XCTFail("Case \(parityCase.id): target lacks active condition \"\(condition.rawValue)\"", file: file, line: line)
            return nil
        }
        return TargetResponseVector(brightness)
    }

    private func makeGrids(
        for parityCase: ParityCorpus.Case,
        weights: ChannelWeights,
        file: StaticString,
        line: UInt
    ) -> [LightingCondition: BrightnessGrid]? {
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for (condition, _) in weights.activeEntries {
            guard let value = parityCase.target[condition.rawValue] else { return nil }
            grids[condition] = BrightnessGrid(width: 1, height: 1, values: [value])
        }
        return grids
    }

    private func validateKeys(
        _ keys: Dictionary<String, Double>.Keys,
        kind: String,
        caseID: String,
        file: StaticString,
        line: UInt
    ) -> Bool {
        let unknown = keys.filter { LightingCondition(rawValue: $0) == nil }.sorted()
        guard unknown.isEmpty else {
            XCTFail("Case \(caseID): unknown light-source key(s) \(unknown) in \(kind)", file: file, line: line)
            return false
        }
        return true
    }

    // MARK: Scorer-level parity

    private func verifyScorerOutcomes(
        _ parityCase: ParityCorpus.Case,
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights,
        file: StaticString,
        line: UInt
    ) {
        let scorer = WeightedSquaredErrorScorer()
        var scores: [Int: Double] = [:]
        var excluded = Set<Int>()
        for color in palette {
            switch scorer.score(candidate: color, target: target, weights: weights) {
            case .score(let value): scores[color.id] = value
            case .excluded: excluded.insert(color.id)
            }
        }

        if let expectedExcluded = parityCase.excludedCandidateIds {
            XCTAssertEqual(
                excluded.sorted(), expectedExcluded.sorted(),
                "Case \(parityCase.id): excluded candidates diverge from the Elixir corpus",
                file: file, line: line
            )
        }

        guard let minScore = scores.values.min() else {
            if parityCase.expectedSelectedId != nil {
                XCTFail(
                    "Case \(parityCase.id): every candidate is excluded but the corpus expects selection of \(parityCase.expectedSelectedId!)",
                    file: file, line: line
                )
            }
            return
        }

        guard let tieIds = parityCase.tieCandidateIds else { return }
        let achieving = scores.filter { abs($0.value - minScore) < Self.scoreAccuracy }
            .keys.sorted()
        XCTAssertEqual(
            achieving, tieIds.sorted(),
            "Case \(parityCase.id): tie set diverges from the Elixir corpus",
            file: file, line: line
        )
        let earliestTied = palette.first { tieIds.contains($0.id) }
        XCTAssertEqual(
            earliestTied?.id, parityCase.expectedSelectedId,
            "Case \(parityCase.id): ties must resolve to the earliest candidate in palette order",
            file: file, line: line
        )
    }

    // MARK: Solver-level parity

    private func verifySolverSelection(
        _ parityCase: ParityCorpus.Case,
        palette: [PaletteColor],
        grids: [LightingCondition: BrightnessGrid],
        weights: ChannelWeights,
        file: StaticString,
        line: UInt
    ) {
        do {
            let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)
            let selectedIndex = result.colorIndex(x: 0, y: 0)
            guard let expectedId = parityCase.expectedSelectedId else {
                XCTAssertNil(
                    selectedIndex,
                    "Case \(parityCase.id): corpus expects no eligible candidate but one was selected",
                    file: file, line: line
                )
                XCTAssertEqual(result.unmatchedCellCount, 1, "Case \(parityCase.id)", file: file, line: line)
                return
            }
            guard let selectedIndex else {
                XCTFail("Case \(parityCase.id): expected selection of color \(expectedId) but the cell is unmatched", file: file, line: line)
                return
            }
            XCTAssertEqual(
                palette[selectedIndex].id, expectedId,
                "Case \(parityCase.id): solver selection diverges from the Elixir corpus",
                file: file, line: line
            )
            if let expectedScore = parityCase.expectedScore {
                XCTAssertEqual(
                    result.error(x: 0, y: 0), expectedScore, accuracy: Self.scoreAccuracy,
                    "Case \(parityCase.id): winning score diverges from the Elixir corpus",
                    file: file, line: line
                )
            }
        } catch {
            XCTFail("Case \(parityCase.id): solver threw \(error)", file: file, line: line)
        }
    }

    // MARK: Reference case

    /// The reference corpus document shown in `docs/solver-parity-corpus.md`.
    private static let referenceCorpusJSON = """
    {
      "version": 1,
      "source": "reference case mirroring the Elixir WeightedSquaredError doctest",
      "cases": [
        {
          "id": "doctest",
          "description": "Doctest vector (score 0.205) with a tied duplicate, a farther candidate, and one excluded for a missing LPS measurement.",
          "palette": [
            {"id": 1, "hex": "#51140F", "responses": {"white": 0.5, "red": 0.1, "green": 0.4, "lps": 0.3}},
            {"id": 2, "hex": "#511428", "responses": {"white": 0.5, "red": 0.4, "green": 0.4, "lps": 0.3}},
            {"id": 3, "hex": "#333333", "responses": {"white": 0.5, "red": 0.1, "green": 0.4}},
            {"id": 4, "hex": "#51140F", "responses": {"white": 0.5, "red": 0.1, "green": 0.4, "lps": 0.3}}
          ],
          "target": {"white": 0.8, "red": 0.2, "green": 0.7, "lps": 0.5},
          "weights": {"white": 0.5, "red": 1.0, "green": 1.0, "blue": 0.0, "lps": 1.5},
          "expected_selected_id": 1,
          "expected_score": 0.205,
          "tie_candidate_ids": [1, 4],
          "excluded_candidate_ids": [3]
        }
      ]
    }
    """
}

private extension ChannelWeights {
    subscript(condition: LightingCondition) -> Double {
        get { weight(for: condition) }
        set {
            switch condition {
            case .white: white = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            case .lps: lps = newValue
            }
        }
    }
}
