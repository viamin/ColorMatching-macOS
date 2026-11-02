import XCTest
@testable import ColorComposerCore

/// Solver parity against the committed corpus.
///
/// The corpus (`Fixtures/solver_parity_corpus.json`) mirrors the expectations
/// published by the `color_matching` server for its `WeightedSquaredError`
/// solver (the parity corpus from viamin/color_matching#111). Every case pins:
/// exact selected color ids, per-cell errors, earliest-palette-index
/// tie-breaking, exclusion of candidates missing an active-channel
/// measurement (never zero-filling), and channel-weight handling.
///
/// Both solver paths are exercised: the optimized contiguous fast path used
/// in production (`CompositionSolver()` with the default scorer) and the
/// general per-candidate path (via a forwarding scorer), so the corpus also
/// guards fast-path/general-path divergence.
///
/// See `docs/solver-parity-corpus.md` for the corpus format and refresh flow.
final class SolverParityCorpusTests: XCTestCase {
    private static let corpusURL = URL(fileURLWithPath: #filePath, isDirectory: false)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/solver_parity_corpus.json", isDirectory: false)

    private func loadCorpus() throws -> ParityCorpus {
        guard FileManager.default.fileExists(atPath: Self.corpusURL.path) else {
            XCTFail("Parity corpus fixture is missing at \(Self.corpusURL.path)")
            throw FileNotFoundError(corpusURL: Self.corpusURL)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: Self.corpusURL))
    }

    private struct FileNotFoundError: Error {
        let corpusURL: URL
    }

    /// Guards the committed corpus against format drift: a corpus refreshed
    /// from upstream with an unknown version, scorer, or tie-break policy must
    /// fail loudly here rather than silently checking the wrong contract.
    func testCorpusDeclaresTheWeightedSquaredErrorContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.version, 1, "Unexpected corpus version; update the loader for the new format")
        XCTAssertEqual(corpus.scorer, "weighted_squared_error")
        XCTAssertEqual(corpus.tieBreak, "earliest_palette_index")
        XCTAssertFalse(corpus.cases.isEmpty, "A parity corpus with no cases verifies nothing")
    }

    /// The corpus must keep covering the parity rules the issue calls out:
    /// ties, exclusions, and weight handling. A refresh that drops a category
    /// would quietly narrow the guarantee.
    func testCorpusCoversTiesExclusionsAndWeightHandling() throws {
        let names = try loadCorpus().cases.map(\.name)

        XCTAssertTrue(names.contains { $0.contains("tie") }, "Corpus has no tie case: \(names)")
        XCTAssertTrue(names.contains { $0.contains("excluded") }, "Corpus has no exclusion case: \(names)")
        XCTAssertTrue(names.contains { $0.contains("weight") }, "Corpus has no weight-handling case: \(names)")
    }

    /// Production path: the default solver runs the optimized fast path.
    func testFastPathSelectionsMatchCorpusExactly() throws {
        try assertSelectionsMatchCorpus(using: CompositionSolver())
    }

    /// The general per-candidate path must agree with the fast path; the
    /// Elixir solver has a single selection policy shared by both.
    func testGeneralPathSelectionsMatchCorpusExactly() throws {
        try assertSelectionsMatchCorpus(using: CompositionSolver(scorer: ForwardingScorer()))
    }

    // MARK: - Runner

    private func assertSelectionsMatchCorpus(
        using solver: CompositionSolver,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let corpus = try loadCorpus()

        for testCase in corpus.cases {
            try run(testCase, solver: solver, file: file, line: line)
        }
    }

    private func run(
        _ testCase: ParityCorpus.Case,
        solver: CompositionSolver,
        file: StaticString,
        line: UInt
    ) throws {
        let palette = try domainPalette(for: testCase)
        let weights = testCase.weights.channelWeights
        let active = weights.activeEntries.map(\.condition)

        XCTAssertEqual(
            testCase.targets.count, testCase.expectedSelections.count,
            "Case '\(testCase.name)': every target needs an expected selection",
            file: file, line: line
        )

        // One row of targets: grid width = target count, height = 1.
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for condition in active {
            var values: [Double] = []
            values.reserveCapacity(testCase.targets.count)
            for (index, target) in testCase.targets.enumerated() {
                let value = try XCTUnwrap(
                    target.value(for: condition),
                    "Case '\(testCase.name)' target \(index) lacks active channel \(condition.rawValue)",
                    file: file, line: line
                )
                values.append(value)
            }
            grids[condition] = BrightnessGrid(width: testCase.targets.count, height: 1, values: values)
        }

        let result = try solver.solve(palette: palette, sourceGrids: grids, weights: weights)

        XCTAssertEqual(
            result.excludedCandidateCount, testCase.expectedExcludedCount,
            "Case '\(testCase.name)': excluded-candidate count",
            file: file, line: line
        )
        XCTAssertEqual(result.unmatchedCellCount, testCase.expectedSelections.filter { $0.colorId == nil }.count,
            "Case '\(testCase.name)': unmatched-cell count",
            file: file, line: line
        )

        for (x, selection) in testCase.expectedSelections.enumerated() {
            let index = result.colorIndex(x: x, y: 0)

            if let expectedID = selection.colorId {
                let matched = try XCTUnwrap(index, "Case '\(testCase.name)' target \(x): expected a selection", file: file, line: line)
                XCTAssertEqual(
                    palette[matched].id, expectedID,
                    "Case '\(testCase.name)' target \(x): selected color",
                    file: file, line: line
                )
                if let expectedError = selection.error {
                    XCTAssertEqual(
                        result.error(x: x, y: 0), expectedError, accuracy: 1e-9,
                        "Case '\(testCase.name)' target \(x): error",
                        file: file, line: line
                    )
                }
            } else {
                XCTAssertNil(
                    index,
                    "Case '\(testCase.name)' target \(x): expected no eligible selection",
                    file: file, line: line
                )
                XCTAssertTrue(
                    result.error(x: x, y: 0).isInfinite,
                    "Case '\(testCase.name)' target \(x): unmatched cells report infinite error",
                    file: file, line: line
                )
            }
        }
    }

    private func domainPalette(for testCase: ParityCorpus.Case) throws -> [PaletteColor] {
        try testCase.palette.map { fixture in
            guard let rgb = RGBColor(hex: fixture.hex) else {
                throw NSError(
                    domain: "SolverParityCorpusTests", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Corpus color \(fixture.id) has unparseable hex '\(fixture.hex)'"]
                )
            }
            var responses: [LightingCondition: IlluminationResponse] = [:]
            for (key, brightness) in fixture.responses {
                if let condition = LightingCondition(rawValue: key) {
                    responses[condition] = IlluminationResponse(brightness: brightness)
                }
            }
            return PaletteColor(id: fixture.id, hex: fixture.hex, rgb: rgb, responses: responses)
        }
    }
}

/// Forwards every score to `WeightedSquaredErrorScorer` while defeating the
/// solver's `is WeightedSquaredErrorScorer` fast-path check, so the corpus
/// runs through the general per-candidate path too.
private struct ForwardingScorer: CompositionScorer {
    private let base = WeightedSquaredErrorScorer()

    func score(
        candidate: PaletteColor,
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> ScorerResult {
        base.score(candidate: candidate, target: target, weights: weights)
    }
}

// MARK: - Corpus wire format (JSON, snake_case keys)

private struct ParityCorpus: Codable {
    struct Case: Codable {
        struct FixtureColor: Codable {
            let id: Int
            let hex: String
            let responses: [String: Double]
        }

        struct WeightSet: Codable {
            let white: Double
            let red: Double
            let green: Double
            let blue: Double
            let lps: Double

            var channelWeights: ChannelWeights {
                ChannelWeights(white: white, red: red, green: green, blue: blue, lps: lps)
            }
        }

        struct Target: Codable {
            let white: Double?
            let red: Double?
            let green: Double?
            let blue: Double?
            let lps: Double?

            func value(for condition: LightingCondition) -> Double? {
                switch condition {
                case .white: return white
                case .red: return red
                case .green: return green
                case .blue: return blue
                case .lps: return lps
                }
            }
        }

        struct Selection: Codable {
            /// Expected palette color id, or `nil` when no candidate is eligible.
            let colorId: Int?
            /// Expected weighted squared error, or `nil` alongside a nil color id.
            let error: Double?
        }

        let name: String
        let notes: String?
        let weights: WeightSet
        let palette: [FixtureColor]
        let targets: [Target]
        let expectedSelections: [Selection]
        let expectedExcludedCount: Int
    }

    let version: Int
    let scorer: String
    let tieBreak: String
    let generator: String?
    let cases: [Case]
}
