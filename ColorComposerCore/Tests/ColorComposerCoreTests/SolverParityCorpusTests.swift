import Foundation
import XCTest
@testable import ColorComposerCore

/// Loads the committed solver parity corpus and asserts that
/// `WeightedSquaredErrorScorer` and `CompositionSolver` reproduce the Elixir
/// `ColorMatching.WeightedSquaredError` / `IlluminantMatching.best_match/4`
/// outcomes exactly — including tie cases, exclusions, and weight handling.
///
/// The corpus is a data file, not inline fixtures, so the same harness can
/// consume the machine-generated corpus from viamin/color_matching#111 the
/// moment it lands: set `SOLVER_PARITY_CORPUS_PATH` to that file, or replace
/// the committed fixture. See `docs/solver-parity-corpus.md` for the schema
/// and refresh instructions.
final class SolverParityCorpusTests: XCTestCase {
    private enum ParityCorpusError: Error {
        case malformed(String)
    }

    // MARK: - Corpus loading

    private func loadCorpus() throws -> ParityCorpus {
        let url = try XCTUnwrap(
            Self.corpusURL(),
            "No parity corpus found: set SOLVER_PARITY_CORPUS_PATH or commit "
                + "solver_parity_corpus.json next to SolverParityCorpusTests.swift"
        )
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }

    /// Override corpus first, then the fixture committed next to this source
    /// file, then the copy SwiftPM bundles into the test target.
    private static func corpusURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["SOLVER_PARITY_CORPUS_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let alongsideSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("solver_parity_corpus.json")
        if FileManager.default.fileExists(atPath: alongsideSource.path) {
            return alongsideSource
        }
        return Bundle.module.url(forResource: "solver_parity_corpus", withExtension: "json")
    }

    // MARK: - Score cases

    func testCorpusScoreCasesMatchReferenceOutcomesExactly() throws {
        let corpus = try loadCorpus()
        let cases = corpus.cases.filter { $0.kind == "score" }
        try XCTSkipIf(cases.isEmpty, "corpus carries no score cases")
        XCTAssertEqual(corpus.version, 1, "unsupported corpus version — update the harness")

        for parityCase in cases {
            try runScoreCase(parityCase)
        }
    }

    private func runScoreCase(_ parityCase: ParityCase) throws {
        let weights = try XCTUnwrap(makeWeights(parityCase.weights), "case \(parityCase.id): unknown condition key")
        let candidateMap = try XCTUnwrap(parityCase.candidate, "case \(parityCase.id): score case lacks candidate")
        let targetMap = try XCTUnwrap(parityCase.target, "case \(parityCase.id): score case lacks target")
        let responses = try XCTUnwrap(makeResponses(candidateMap), "case \(parityCase.id): unknown condition key")
        let candidate = PaletteColor(
            id: 0,
            hex: "#000000",
            rgb: RGBColor(hex: "#000000")!,
            responses: responses
        )
        let target = TargetResponseVector(
            try XCTUnwrap(makeBrightness(targetMap), "case \(parityCase.id): unknown condition key")
        )

        let result = WeightedSquaredErrorScorer().score(candidate: candidate, target: target, weights: weights)

        switch (result, parityCase.expected.outcome) {
        case (.excluded, "excluded"):
            return
        case (.score(let value), "score"):
            let expected = try XCTUnwrap(parityCase.expected.value, "case \(parityCase.id): expected value missing")
            XCTAssertEqual(value, expected, accuracy: 1e-9, "case \(parityCase.id): score mismatch")
        case (.score, let outcome):
            XCTFail("case \(parityCase.id): expected \(outcome ?? "nil") but candidate was rankable")
        case (.excluded, let outcome):
            XCTFail("case \(parityCase.id): expected \(outcome ?? "nil") but candidate was excluded")
        }
    }

    // MARK: - Selection cases

    func testCorpusSelectionCasesMatchReferenceBestMatchExactly() throws {
        let corpus = try loadCorpus()
        let cases = corpus.cases.filter { $0.kind == "selection" }
        try XCTSkipIf(cases.isEmpty, "corpus carries no selection cases")

        for parityCase in cases {
            try runSelectionCase(parityCase)
        }
    }

    private func runSelectionCase(_ parityCase: ParityCase) throws {
        let weights = try XCTUnwrap(makeWeights(parityCase.weights), "case \(parityCase.id): unknown condition key")
        let palette = try makePalette(parityCase)
        let cells = try XCTUnwrap(parityCase.cells, "case \(parityCase.id): selection case lacks cells")
        let cellMaps = try cells.map { cell -> [LightingCondition: Double] in
            guard let map = makeBrightness(cell) else {
                throw ParityCorpusError.malformed(parityCase.id)
            }
            return map
        }

        let width = parityCase.gridWidth ?? cells.count
        let height = parityCase.gridHeight ?? 1
        XCTAssertEqual(cellMaps.count, width * height, "case \(parityCase.id): cells do not fill the grid")

        var sourceGrids: [LightingCondition: BrightnessGrid] = [:]
        for condition in weights.activeConditions {
            let values = try cellMaps.map { cell -> Double in
                guard let value = cell[condition] else {
                    throw ParityCorpusError.malformed("\(parityCase.id): cell missing active condition \(condition.rawValue)")
                }
                return value
            }
            sourceGrids[condition] = BrightnessGrid(width: width, height: height, values: values)
        }

        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: sourceGrids,
            weights: weights
        )

        let expectedSelections = try XCTUnwrap(parityCase.expected.selections, "case \(parityCase.id): expected selections missing")
        let expectedErrors = try XCTUnwrap(parityCase.expected.errors, "case \(parityCase.id): expected errors missing")
        XCTAssertEqual(expectedSelections.count, cellMaps.count, "case \(parityCase.id): selection count")
        XCTAssertEqual(expectedErrors.count, cellMaps.count, "case \(parityCase.id): error count")

        for index in 0..<cellMaps.count {
            let cellX = index % width
            let cellY = index / width
            let selectedID = result.colorIndex(x: cellX, y: cellY).map { palette[$0].id }
            XCTAssertEqual(
                selectedID,
                expectedSelections[index],
                "case \(parityCase.id) cell \(index): selection mismatch"
            )
            if let expectedError = expectedErrors[index] {
                XCTAssertEqual(
                    result.error(x: cellX, y: cellY),
                    expectedError,
                    accuracy: 1e-9,
                    "case \(parityCase.id) cell \(index): error mismatch"
                )
            } else {
                XCTAssertTrue(
                    result.error(x: cellX, y: cellY).isInfinite,
                    "case \(parityCase.id) cell \(index): expected an unmatched cell"
                )
            }
        }

        if let expectedExcluded = parityCase.expected.excludedCandidateCount {
            XCTAssertEqual(
                result.excludedCandidateCount,
                expectedExcluded,
                "case \(parityCase.id): excluded candidate count mismatch"
            )
        }
    }

    // MARK: - Corpus coverage guards

    /// Guards against a truncated or mis-transcribed refresh: the corpus must
    /// keep covering the parity-relevant behaviors the issue calls out — ties,
    /// exclusions, and zero-weight handling — and must anchor on the Elixir
    /// doctest. Marker naming convention: see docs/solver-parity-corpus.md.
    func testCorpusCoversTiesExclusionsAndWeightHandling() throws {
        let corpus = try loadCorpus()
        let ids = corpus.cases.map(\.id)
        let joined = ids.joined(separator: " ")

        XCTAssertTrue(joined.contains("doctest"), "corpus lost its Elixir doctest anchor case")
        XCTAssertTrue(joined.contains("zero-weight"), "corpus lost zero-weight coverage")
        XCTAssertTrue(joined.contains("excluded"), "corpus lost exclusion coverage")

        let tieCases = corpus.cases.filter { $0.expected.ties?.contains(true) == true }
        XCTAssertFalse(tieCases.isEmpty, "corpus lost its tie cases")

        let excludedScores = corpus.cases.filter { $0.expected.outcome == "excluded" }
        XCTAssertGreaterThanOrEqual(excludedScores.count, 2, "corpus needs candidate- and target-side exclusions")
    }

    // MARK: - Corpus-to-domain mapping

    private func makePalette(_ parityCase: ParityCase) throws -> [PaletteColor] {
        let entries = try XCTUnwrap(parityCase.palette, "case \(parityCase.id): selection case lacks palette")
        return try entries.map { entry in
            let hex = entry.hex ?? "#000000"
            guard let rgb = RGBColor(hex: hex),
                  let responses = makeResponses(entry.responses ?? [:]) else {
                throw ParityCorpusError.malformed("\(parityCase.id): bad palette entry \(entry.id)")
            }
            return PaletteColor(id: entry.id, hex: hex, rgb: rgb, responses: responses)
        }
    }

    private func makeWeights(_ raw: [String: Double]) -> ChannelWeights? {
        guard let parsed = makeBrightness(raw) else { return nil }
        return ChannelWeights(
            white: parsed[.white] ?? 0,
            red: parsed[.red] ?? 0,
            green: parsed[.green] ?? 0,
            blue: parsed[.blue] ?? 0,
            lps: parsed[.lps] ?? 0
        )
    }

    private func makeBrightness(_ raw: [String: Double]) -> [LightingCondition: Double]? {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in raw {
            guard let condition = LightingCondition(rawValue: key) else { return nil }
            brightness[condition] = value
        }
        return brightness
    }

    private func makeResponses(_ raw: [String: Double]) -> [LightingCondition: IlluminationResponse]? {
        guard let brightness = makeBrightness(raw) else { return nil }
        return brightness.mapValues { IlluminationResponse(brightness: $0) }
    }
}

// MARK: - Corpus wire model

private struct ParityCorpus: Decodable {
    let version: Int
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let id: String
    /// `"score"` compares one candidate against one target;
    /// `"selection"` runs the solver over a palette and per-cell targets.
    let kind: String
    let description: String?
    let weights: [String: Double]
    let candidate: [String: Double]?
    let target: [String: Double]?
    let palette: [ParityPaletteColor]?
    let cells: [[String: Double]]?
    let gridWidth: Int?
    let gridHeight: Int?
    let expected: ParityExpectation
}

private struct ParityPaletteColor: Decodable {
    let id: Int
    let hex: String?
    let responses: [String: Double]?
}

private struct ParityExpectation: Decodable {
    /// Score cases: `"score"` or `"excluded"`.
    let outcome: String?
    /// Score cases: the expected score when the outcome is `"score"`.
    let value: Double?
    /// Selection cases: expected color id per cell (`nil` element = unmatched).
    let selections: [Int?]?
    /// Selection cases: expected error per cell (`nil` element = infinity).
    let errors: [Double?]?
    /// Selection cases: whether the winning score was shared by 2+ candidates.
    let ties: [Bool]?
    let excludedCandidateCount: Int?
}
