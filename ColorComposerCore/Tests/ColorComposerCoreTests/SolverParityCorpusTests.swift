import XCTest
@testable import ColorComposerCore

/// Solver parity corpus suite (issue #39).
///
/// Loads the committed corpus at `Fixtures/solver_parity_corpus.json` —
/// exported from the Elixir `ColorMatching.WeightedSquaredError` solver
/// (viamin/color_matching#111) — and asserts that
/// `WeightedSquaredErrorScorer` and `CompositionSolver` selections match the
/// expected outputs exactly: selected color id, winning score, exclusion set,
/// tie-breaking (earliest palette candidate), and weight handling.
///
/// The corpus is loaded relative to `#filePath` rather than a bundle resource
/// so it works under `swift test` on both Apple and Linux hosts without a
/// resource-declaration change. See `docs/solver-parity-corpus.md` for the
/// schema and the refresh procedure.
final class SolverParityCorpusTests: XCTestCase {
    private enum CorpusError: Error, CustomStringConvertible {
        case fixtureMissing(String)

        var description: String {
            switch self {
            case .fixtureMissing(let path): return "Parity corpus fixture missing at \(path)"
            }
        }
    }

    // MARK: - Corpus wire models

    private struct ParityCorpus: Codable {
        let version: Int
        let scorer: String
        let cases: [ParityCase]
    }

    private struct ParityCase: Codable {
        let id: String
        let description: String?
        let tie: Bool?
        let weights: [String: Double]
        let target: [String: Double]
        let palette: [ParityColor]
        let expected: ParityExpectation
    }

    private struct ParityColor: Codable {
        let id: Int
        let hex: String
        let responses: [String: Double]
    }

    private struct ParityExpectation: Codable {
        let selectedId: Int?
        let score: Double?
        let excludedIds: [Int]?
    }

    // MARK: - Loading and conversion

    private func loadCorpus(file: StaticString = #filePath, line: UInt = #line) throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("solver_parity_corpus.json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            XCTFail(CorpusError.fixtureMissing(fixtureURL.path).description, file: file, line: line)
            throw CorpusError.fixtureMissing(fixtureURL.path)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: try Data(contentsOf: fixtureURL))
    }

    private func condition(
        _ key: String, caseID: String, field: String
    ) -> LightingCondition? {
        guard let condition = LightingCondition(rawValue: key) else {
            XCTFail("Case \(caseID): unknown light source key \"\(key)\" in \(field)")
            return nil
        }
        return condition
    }

    private func makeWeights(_ raw: [String: Double], caseID: String) -> ChannelWeights? {
        var values: [LightingCondition: Double] = [:]
        for (key, value) in raw {
            guard let condition = condition(key, caseID: caseID, field: "weights") else { return nil }
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

    private func makeResponseMap(
        _ raw: [String: Double], caseID: String, field: String
    ) -> [LightingCondition: Double]? {
        var values: [LightingCondition: Double] = [:]
        for (key, value) in raw {
            guard let condition = condition(key, caseID: caseID, field: field) else { return nil }
            values[condition] = value
        }
        return values
    }

    private func makePalette(_ raw: [ParityColor], caseID: String) -> [PaletteColor] {
        var palette: [PaletteColor] = []
        for color in raw {
            guard let rgb = RGBColor(hex: color.hex) else {
                XCTFail("Case \(caseID): color \(color.id) has unparseable hex \"\(color.hex)\"")
                continue
            }
            var responses: [LightingCondition: IlluminationResponse] = [:]
            for (key, value) in color.responses {
                guard let condition = condition(key, caseID: caseID, field: "color \(color.id) responses") else { continue }
                responses[condition] = IlluminationResponse(brightness: value)
            }
            palette.append(PaletteColor(id: color.id, hex: color.hex, rgb: rgb, responses: responses))
        }
        return palette
    }

    // MARK: - Parity assertions

    /// Asserts one corpus case end to end: solver selection on a 1x1 grid
    /// (the app's real selection path, including earliest-wins ties), the
    /// winning score, and the scorer-level exclusion set.
    private func assertParity(_ caseItem: ParityCase) throws {
        let weights = try XCTUnwrap(makeWeights(caseItem.weights, caseID: caseItem.id))
        let targetValues = try XCTUnwrap(makeResponseMap(caseItem.target, caseID: caseItem.id, field: "target"))
        let palette = makePalette(caseItem.palette, caseID: caseItem.id)
        let target = TargetResponseVector(targetValues)

        var grids: [LightingCondition: BrightnessGrid] = [:]
        for (condition, value) in targetValues {
            grids[condition] = BrightnessGrid(width: 1, height: 1, values: [value])
        }
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)

        if let selectedID = caseItem.expected.selectedId {
            let selectedIndex = try XCTUnwrap(
                palette.firstIndex(where: { $0.id == selectedID }),
                "Case \(caseItem.id): expected selected id \(selectedID) is not in the palette"
            )
            XCTAssertEqual(
                result.colorIndex(x: 0, y: 0), selectedIndex,
                "Case \(caseItem.id): solver selection mismatch"
            )
            if let expectedScore = caseItem.expected.score {
                XCTAssertEqual(
                    result.error(x: 0, y: 0), expectedScore, accuracy: 1e-9,
                    "Case \(caseItem.id): solver error mismatch"
                )
                guard case .score(let value) = WeightedSquaredErrorScorer().score(
                    candidate: palette[selectedIndex], target: target, weights: weights
                ) else {
                    return XCTFail("Case \(caseItem.id): selected candidate excluded by the scorer")
                }
                XCTAssertEqual(value, expectedScore, accuracy: 1e-9, "Case \(caseItem.id): scorer score mismatch")
            }
        } else {
            XCTAssertNil(result.colorIndex(x: 0, y: 0), "Case \(caseItem.id): expected no selection")
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, "Case \(caseItem.id): expected infinite error")
            XCTAssertEqual(result.unmatchedCellCount, 1, "Case \(caseItem.id): expected one unmatched cell")
        }

        let scorer = WeightedSquaredErrorScorer()
        let excluded = palette.filter {
            scorer.score(candidate: $0, target: target, weights: weights) == .excluded
        }.map(\.id).sorted()
        XCTAssertEqual(
            excluded, (caseItem.expected.excludedIds ?? []).sorted(),
            "Case \(caseItem.id): exclusion set mismatch"
        )
        XCTAssertEqual(
            result.excludedCandidateCount, (caseItem.expected.excludedIds ?? []).count,
            "Case \(caseItem.id): solver excludedCandidateCount mismatch"
        )
    }

    // MARK: - Tests

    /// The core parity assertion: every corpus case must reproduce the
    /// Elixir solver's expected selection, score, and exclusions exactly.
    func testSelectionsMatchCorpusExactly() throws {
        let corpus = try loadCorpus()
        for caseItem in corpus.cases {
            try assertParity(caseItem)
        }
    }

    /// The corpus must stay a meaningful parity net: versioned, unique,
    /// well-formed, and covering ties, exclusions, and the all-excluded case.
    func testCorpusIntegrity() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.version, 1, "Unsupported corpus schema version")
        XCTAssertEqual(corpus.scorer, "weighted_squared_error", "Corpus targets a different solver")
        XCTAssertGreaterThanOrEqual(corpus.cases.count, 10, "Corpus is too small to be a parity net")

        let ids = corpus.cases.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Duplicate corpus case ids")

        XCTAssertTrue(corpus.cases.contains { $0.tie == true }, "Corpus must cover tie cases")
        XCTAssertTrue(
            corpus.cases.contains { !($0.expected.excludedIds ?? []).isEmpty },
            "Corpus must cover exclusion cases"
        )
        XCTAssertTrue(
            corpus.cases.contains { $0.expected.selectedId == nil },
            "Corpus must cover the all-candidates-excluded case"
        )

        for caseItem in corpus.cases {
            let weights = try XCTUnwrap(makeWeights(caseItem.weights, caseID: caseItem.id))
            let targetValues = try XCTUnwrap(makeResponseMap(caseItem.target, caseID: caseItem.id, field: "target"))
            XCTAssertFalse(weights.activeEntries.isEmpty, "Case \(caseItem.id): no channel has weight > 0")
            for (condition, _) in weights.activeEntries {
                XCTAssertNotNil(
                    targetValues[condition],
                    "Case \(caseItem.id): target lacks active channel \(condition.rawValue)"
                )
            }
            let paletteIDs = Set(caseItem.palette.map(\.id))
            XCTAssertEqual(paletteIDs.count, caseItem.palette.count, "Case \(caseItem.id): duplicate palette ids")
            if let selectedID = caseItem.expected.selectedId {
                XCTAssertTrue(paletteIDs.contains(selectedID), "Case \(caseItem.id): selection not in palette")
            }
            for excludedID in caseItem.expected.excludedIds ?? [] {
                XCTAssertTrue(paletteIDs.contains(excludedID), "Case \(caseItem.id): excluded id not in palette")
            }
        }
    }

    /// Tie-flagged cases must genuinely tie, and the winner must be the
    /// earliest palette candidate achieving the minimum score — the policy
    /// shared with the Elixir `best_match` selection.
    func testTieCasesSelectEarliestCandidateAtMinimumScore() throws {
        let corpus = try loadCorpus()
        let tieCases = corpus.cases.filter { $0.tie == true }
        XCTAssertFalse(tieCases.isEmpty, "Corpus must include tie-flagged cases")

        for caseItem in tieCases {
            let weights = try XCTUnwrap(makeWeights(caseItem.weights, caseID: caseItem.id))
            let target = TargetResponseVector(
                try XCTUnwrap(makeResponseMap(caseItem.target, caseID: caseItem.id, field: "target"))
            )
            let palette = makePalette(caseItem.palette, caseID: caseItem.id)

            let scores: [Double?] = palette.map { color in
                guard case .score(let value) = WeightedSquaredErrorScorer().score(
                    candidate: color, target: target, weights: weights
                ) else { return nil }
                return value
            }
            let minimum = try XCTUnwrap(scores.compactMap { $0 }.min(), "Case \(caseItem.id): no rankable candidate")
            let achievers = scores.indices.filter { index in
                guard let score = scores[index] else { return false }
                return abs(score - minimum) <= 1e-12
            }
            XCTAssertGreaterThanOrEqual(achievers.count, 2, "Case \(caseItem.id): tie-flagged but no tie exists")

            let expectedID = try XCTUnwrap(caseItem.expected.selectedId, "Case \(caseItem.id): tie case needs a selection")
            let selectedIndex = try XCTUnwrap(palette.firstIndex { $0.id == expectedID })
            XCTAssertEqual(
                achievers.first, selectedIndex,
                "Case \(caseItem.id): tie must resolve to the earliest minimum-score candidate"
            )
        }
    }

    /// The weight-emphasis pair proves weights flow through scoring: one
    /// palette and target, two weight sets, two different winners.
    func testWeightEmphasisPairFlipsSelection() throws {
        let corpus = try loadCorpus()
        func caseByID(_ id: String) throws -> ParityCase {
            try XCTUnwrap(corpus.cases.first { $0.id == id }, "Corpus case \"\(id)\" is missing")
        }
        let white = try caseByID("weight_emphasis_white")
        let red = try caseByID("weight_emphasis_red")

        XCTAssertEqual(white.palette.map(\.id), red.palette.map(\.id), "Weight-flip pair must share one palette")
        XCTAssertEqual(white.target, red.target, "Weight-flip pair must share one target")
        XCTAssertNotEqual(
            white.expected.selectedId, red.expected.selectedId,
            "Weight-flip pair must demonstrate weights changing the winner"
        )

        try assertParity(white)
        try assertParity(red)
    }
}
