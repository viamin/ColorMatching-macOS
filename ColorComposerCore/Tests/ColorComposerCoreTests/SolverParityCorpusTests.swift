import Foundation
import XCTest
@testable import ColorComposerCore

/// Solver-parity coverage driven by the committed corpus exported from the
/// Elixir `WeightedSquaredError` solver (viamin/color_matching#111).
///
/// The corpus lives at `Fixtures/solver-parity-corpus.json` next to this file
/// (see `docs/solver-parity-corpus.md` for the schema and refresh workflow).
/// Every case pins: which palette color the solver must select per target
/// vector (earliest-wins on exact ties), the expected score when asserted,
/// exclusion of colors missing a measurement for a positive-weight channel,
/// and that zero-weight channels never exclude a candidate.
final class SolverParityCorpusTests: XCTestCase {
    private static let fixtureName = "solver-parity-corpus.json"
    private static let expectedScorer = "weighted_squared_error"
    private static let scoreTolerance = 1e-9
    private static let tieTolerance = 1e-12

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(fixtureName)")
    }

    private enum CorpusError: Error, CustomStringConvertible {
        case fixtureMissing(String)
        case schema(String)

        var description: String {
            switch self {
            case .fixtureMissing(let path):
                return """
                    solver parity corpus is not committed: expected it at \(path). \
                    Vendor the corpus exported by viamin/color_matching#111 there \
                    (schema and refresh workflow: docs/solver-parity-corpus.md).
                    """
            case .schema(let detail):
                return "solver parity corpus is malformed: \(detail)"
            }
        }
    }

    private struct ParityCorpus: Decodable {
        struct Case: Decodable {
            struct PaletteEntry: Decodable {
                struct Response: Decodable {
                    let brightness: Double
                }
                let id: Int
                let hex: String
                let responses: [String: Response]
            }
            let name: String
            let tags: [String]?
            let weights: [String: Double]
            let palette: [PaletteEntry]
            let targets: [[String: Double]]
            let expectedSelectionIDs: [Int?]
            let expectedScores: [Double?]?

            enum CodingKeys: String, CodingKey {
                case name, tags, weights, palette, targets
                case expectedSelectionIDs = "expected_selection_ids"
                case expectedScores = "expected_scores"
            }
        }
        let version: Int
        let source: String?
        let scorer: String
        let cases: [Case]
    }

    private struct SelectionOutcome {
        let id: Int?
        let score: Double?
        let tiedCount: Int
        let excludedCount: Int
    }

    // MARK: - Corpus presence and shape

    func testCorpusFixtureIsCommittedAndWellFormed() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.scorer, Self.expectedScorer)
        XCTAssertEqual(corpus.version, 1)
        XCTAssertFalse(corpus.cases.isEmpty, "parity corpus must contain at least one case")

        var sawTie = false
        var sawExclusion = false
        for corpusCase in corpus.cases {
            let tags = corpusCase.tags ?? []
            sawTie = sawTie || tags.contains("tie")
            sawExclusion = sawExclusion || tags.contains("exclusion")
            try validateShape(of: corpusCase)
        }
        XCTAssertTrue(sawTie, "corpus must cover tie cases (issue #39)")
        XCTAssertTrue(sawExclusion, "corpus must cover exclusion cases (issue #39)")
    }

    private func validateShape(of corpusCase: ParityCorpus.Case) throws {
        let caseName = corpusCase.name
        XCTAssertFalse(corpusCase.palette.isEmpty, "case '\(caseName)' has an empty palette")
        XCTAssertFalse(corpusCase.targets.isEmpty, "case '\(caseName)' has no targets")
        XCTAssertEqual(
            corpusCase.expectedSelectionIDs.count, corpusCase.targets.count,
            "case '\(caseName)': expected_selection_ids must align with targets"
        )
        if let scores = corpusCase.expectedScores {
            XCTAssertEqual(scores.count, corpusCase.targets.count,
                           "case '\(caseName)': expected_scores must align with targets")
        }
        XCTAssertGreaterThan(
            try makeWeights(corpusCase.weights, caseName: caseName).activeConditions.count, 0,
            "case '\(caseName)': at least one channel weight must be positive"
        )
    }

    // MARK: - Selection parity

    func testSelectionsMatchCorpusExactly() throws {
        let corpus = try loadCorpus()

        for corpusCase in corpus.cases {
            let weights = try makeWeights(corpusCase.weights, caseName: corpusCase.name)
            let palette = try makePalette(corpusCase.palette, caseName: corpusCase.name)

            for (index, rawTarget) in corpusCase.targets.enumerated() {
                let target = try makeTarget(rawTarget, caseName: corpusCase.name)
                let outcome = bestSelection(palette: palette, target: target, weights: weights)
                let expectedID = corpusCase.expectedSelectionIDs[index]
                let context = "case '\(corpusCase.name)' target \(index)"

                XCTAssertEqual(outcome.id, expectedID, "\(context): selection mismatch")
                if let expectedScore = corpusCase.expectedScores?[index], expectedID != nil {
                    guard let score = outcome.score else {
                        return XCTFail("\(context): expected score \(expectedScore) but selection was excluded")
                    }
                    XCTAssertEqual(score, expectedScore, accuracy: Self.scoreTolerance,
                                   "\(context): score mismatch")
                }
            }
        }
    }

    /// A color missing a measurement for any positive-weight channel is
    /// excluded — never treated as zero brightness — mirroring the Elixir
    /// solver's policy. The corpus's exclusions must agree with that rule.
    func testExcludedCandidatesAreExactlyThoseMissingAnActiveMeasurement() throws {
        let corpus = try loadCorpus()

        for corpusCase in corpus.cases {
            let weights = try makeWeights(corpusCase.weights, caseName: corpusCase.name)
            let palette = try makePalette(corpusCase.palette, caseName: corpusCase.name)
            let active = Set(weights.activeConditions)

            for (index, rawTarget) in corpusCase.targets.enumerated() {
                let target = try makeTarget(rawTarget, caseName: corpusCase.name)
                let outcome = bestSelection(palette: palette, target: target, weights: weights)
                let targetCoversActive = active.allSatisfy { target.value(for: $0) != nil }
                let expectedExcluded = palette.filter { color in
                    !targetCoversActive || !color.hasMeasurements(for: active)
                }.count

                XCTAssertEqual(outcome.excludedCount, expectedExcluded,
                               "case '\(corpusCase.name)' target \(index): exclusion policy drift")
            }
        }
    }

    func testTieCasesSelectTheEarliestTiedCandidate() throws {
        let corpus = try loadCorpus()
        let tieCases = corpus.cases.filter { ($0.tags ?? []).contains("tie") }
        XCTAssertFalse(tieCases.isEmpty, "corpus must include tie-tagged cases")

        for corpusCase in tieCases {
            let weights = try makeWeights(corpusCase.weights, caseName: corpusCase.name)
            let palette = try makePalette(corpusCase.palette, caseName: corpusCase.name)

            for (index, rawTarget) in corpusCase.targets.enumerated() {
                let target = try makeTarget(rawTarget, caseName: corpusCase.name)
                let outcome = bestSelection(palette: palette, target: target, weights: weights)
                let context = "case '\(corpusCase.name)' target \(index)"

                XCTAssertGreaterThanOrEqual(outcome.tiedCount, 2,
                                            "\(context): corpus claims a tie but our scorer sees a unique winner")
                guard let expectedID = corpusCase.expectedSelectionIDs[index] else {
                    return XCTFail("\(context): tie case must expect a selection")
                }
                let firstTiedID = palette.first { color in
                    guard case .score(let value) = WeightedSquaredErrorScorer().score(
                        candidate: color, target: target, weights: weights
                    ) else { return false }
                    return abs(value - (outcome.score ?? .infinity)) <= Self.tieTolerance
                }?.id
                XCTAssertEqual(outcome.id, expectedID, "\(context): tie broken to the wrong candidate")
                XCTAssertEqual(firstTiedID, expectedID,
                               "\(context): ties must resolve to the earliest candidate in palette order")
            }
        }
    }

    func testExclusionCasesNeverSelectAnUnmeasuredColor() throws {
        let corpus = try loadCorpus()
        let exclusionCases = corpus.cases.filter { ($0.tags ?? []).contains("exclusion") }
        XCTAssertFalse(exclusionCases.isEmpty, "corpus must include exclusion-tagged cases")

        for corpusCase in exclusionCases {
            let weights = try makeWeights(corpusCase.weights, caseName: corpusCase.name)
            let palette = try makePalette(corpusCase.palette, caseName: corpusCase.name)
            let active = Set(weights.activeConditions)

            for (index, rawTarget) in corpusCase.targets.enumerated() {
                let target = try makeTarget(rawTarget, caseName: corpusCase.name)
                let outcome = bestSelection(palette: palette, target: target, weights: weights)
                let context = "case '\(corpusCase.name)' target \(index)"

                XCTAssertGreaterThanOrEqual(outcome.excludedCount, 1,
                                            "\(context): corpus claims an exclusion but none occurred")
                guard let selectedID = outcome.id,
                      let selected = palette.first(where: { $0.id == selectedID }) else { continue }
                XCTAssertTrue(selected.hasMeasurements(for: active),
                              "\(context): selected color \(selectedID) lacks a required measurement")
            }
        }
    }

    /// End-to-end parity through `CompositionSolver` (the fast path the app
    /// uses), not just the scorer: the per-cell selection must equal the
    /// corpus expectation cell for cell.
    func testSolverFastPathSelectionsMatchCorpus() throws {
        let corpus = try loadCorpus()

        for corpusCase in corpus.cases {
            let weights = try makeWeights(corpusCase.weights, caseName: corpusCase.name)
            let palette = try makePalette(corpusCase.palette, caseName: corpusCase.name)
            let targets = try corpusCase.targets.map { try makeTarget($0, caseName: corpusCase.name) }
            let active = weights.activeConditions
            let solvable = targets.allSatisfy { target in
                active.allSatisfy { target.value(for: $0) != nil }
            }
            if !solvable { continue }

            var grids: [LightingCondition: BrightnessGrid] = [:]
            for condition in active {
                grids[condition] = BrightnessGrid(
                    width: targets.count, height: 1,
                    values: targets.map { $0.value(for: condition)! }
                )
            }
            let result = try CompositionSolver(scorer: WeightedSquaredErrorScorer())
                .solve(palette: palette, sourceGrids: grids, weights: weights)

            for (index, expectedID) in corpusCase.expectedSelectionIDs.enumerated() {
                let resolved = result.colorIndex(x: index, y: 0).flatMap { palette[$0].id }
                XCTAssertEqual(resolved, expectedID,
                               "case '\(corpusCase.name)' cell \(index): solver selection mismatch")
                if let expectedScore = corpusCase.expectedScores?[index], expectedID != nil {
                    XCTAssertEqual(result.error(x: index, y: 0), expectedScore,
                                   accuracy: Self.scoreTolerance,
                                   "case '\(corpusCase.name)' cell \(index): solver error mismatch")
                }
            }
        }
    }

    // MARK: - Loading and conversion

    private func loadCorpus(file: StaticString = #filePath, line: UInt = #line) throws -> ParityCorpus {
        let url = Self.fixtureURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CorpusError.fixtureMissing(url.path)
        }
        do {
            return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
        } catch let error as CorpusError {
            throw error
        } catch {
            throw CorpusError.schema("\(error)")
        }
    }

    private func makeWeights(_ raw: [String: Double], caseName: String) throws -> ChannelWeights {
        var weights = ChannelWeights()
        for (key, value) in raw {
            guard let condition = LightingCondition(rawValue: key) else {
                throw CorpusError.schema("case '\(caseName)': unknown light source '\(key)' in weights")
            }
            switch condition {
            case .white: weights.white = value
            case .red: weights.red = value
            case .green: weights.green = value
            case .blue: weights.blue = value
            case .lps: weights.lps = value
            }
        }
        return weights
    }

    private func makePalette(_ entries: [ParityCorpus.Case.PaletteEntry], caseName: String) throws -> [PaletteColor] {
        try entries.map { entry in
            var responses: [LightingCondition: IlluminationResponse] = [:]
            for (key, response) in entry.responses {
                guard let condition = LightingCondition(rawValue: key) else {
                    throw CorpusError.schema("case '\(caseName)': color \(entry.id) has unknown light source '\(key)'")
                }
                responses[condition] = IlluminationResponse(brightness: response.brightness)
            }
            guard let rgb = RGBColor(hex: entry.hex) else {
                throw CorpusError.schema("case '\(caseName)': color \(entry.id) has unparseable hex '\(entry.hex)'")
            }
            return PaletteColor(id: entry.id, hex: entry.hex, rgb: rgb, responses: responses)
        }
    }

    private func makeTarget(_ raw: [String: Double], caseName: String) throws -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in raw {
            guard let condition = LightingCondition(rawValue: key) else {
                throw CorpusError.schema("case '\(caseName)': target has unknown light source '\(key)'")
            }
            brightness[condition] = value
        }
        return TargetResponseVector(brightness)
    }

    /// Re-derives the selection with the scorer alone, using the solver's
    /// earliest-wins strict `<` comparison, so corpus assertions exercise the
    /// same policy end to end.
    private func bestSelection(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> SelectionOutcome {
        let scorer = WeightedSquaredErrorScorer()
        var scores: [Double?] = []
        var bestIndex: Int?
        var bestScore = Double.infinity

        for color in palette {
            guard case .score(let value) = scorer.score(candidate: color, target: target, weights: weights) else {
                scores.append(nil)
                continue
            }
            scores.append(value)
            if value < bestScore {
                bestScore = value
                bestIndex = scores.count - 1
            }
        }
        let tiedCount = scores.filter { score in
            guard let score else { return false }
            return bestIndex != nil && abs(score - bestScore) <= Self.tieTolerance
        }.count
        return SelectionOutcome(
            id: bestIndex.map { palette[$0].id },
            score: bestIndex == nil ? nil : bestScore,
            tiedCount: tiedCount,
            excludedCount: scores.lazy.filter { $0 == nil }.count
        )
    }
}
