import XCTest
@testable import ColorComposerCore

/// Enforces solver parity with the committed corpus, mirroring the Elixir
/// `ColorMatching.WeightedSquaredError` selections exactly — including ties
/// (earliest candidate wins), exclusions (a missing measurement for any
/// weight > 0 channel is never treated as zero brightness), and weight
/// handling (weight 0 channels are neither required nor contributing).
///
/// The corpus lives at
/// `Tests/ColorComposerCoreTests/Fixtures/parity/weighted_squared_error_parity.json`
/// and is refreshed from the `color_matching` parity suite
/// (viamin/color_matching#111). See `docs/solver-parity-corpus.md` for the
/// schema and refresh procedure.
final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    private static let scoreAccuracy = 1e-12

    private static let corpusFileURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/parity/weighted_squared_error_parity.json")

    private struct ParityFixtureError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    // MARK: - Corpus schema (test-local; see docs/solver-parity-corpus.md)

    private struct ParityCorpus: Codable {
        let corpus: String
        let version: Int
        let cases: [ParityCase]
    }

    private struct ParityCase: Codable {
        let id: String
        let category: String
        let weights: [String: Double]?
        let target: [String: Double]?
        let palette: [ParityColor]
        let expected: ParityExpectation
    }

    private struct ParityColor: Codable {
        let index: Int
        let id: Int
        let name: String?
        let hex: String
        let rgb: ParityRGB?
        let responses: [String: Double]?
    }

    private struct ParityRGB: Codable {
        let r: Int
        let g: Int
        let b: Int
    }

    private struct ParityExpectation: Codable {
        let selectedIndex: Int?
        let selectedId: Int?
        let score: Double?
        let excludedIds: [Int]?
        let tiedIds: [Int]?
        let noSelection: Bool?
    }

    // MARK: - Loading

    private func loadCorpus(file: StaticString = #filePath, line: UInt = #line) throws -> ParityCorpus {
        let url = Self.corpusFileURL
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "Parity corpus is not committed at \(url.path); see docs/solver-parity-corpus.md",
            file: file,
            line: line
        )
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: data)
    }

    // MARK: - Corpus integrity

    func testCorpusFileIsCommittedAndDecodes() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.corpus, "weighted_squared_error")
        XCTAssertEqual(corpus.version, 1)
        XCTAssertFalse(corpus.cases.isEmpty)
    }

    /// The corpus must keep covering every parity-relevant scenario class, so
    /// a future refresh cannot silently drop tie, exclusion, or weight
    /// coverage.
    func testCorpusCoversRequiredScenarioCategories() throws {
        let corpus = try loadCorpus()

        let required: Set<String> = [
            "nearest", "exact_match", "tie", "exclusion",
            "zero_weight_channel", "weight_scaling", "multi_channel"
        ]
        let present = Set(corpus.cases.map(\.category))
        XCTAssertTrue(
            present.isSuperset(of: required),
            "Corpus is missing scenario categories: \(required.subtracting(present).sorted())"
        )
        XCTAssertTrue(
            corpus.cases.contains { !($0.expected.tiedIds ?? []).isEmpty },
            "Corpus must contain at least one tie case with tied_ids"
        )
        XCTAssertTrue(
            corpus.cases.contains { !($0.expected.excludedIds ?? []).isEmpty },
            "Corpus must contain at least one case with excluded candidates"
        )
        XCTAssertTrue(
            corpus.cases.contains { $0.expected.noSelection == true },
            "Corpus must contain at least one no-selection case"
        )
    }

    func testCorpusCaseIDsAreUnique() throws {
        let corpus = try loadCorpus()

        let ids = corpus.cases.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Duplicate case ids in the corpus")
    }

    func testCorpusUsesOnlyCanonicalLightSources() throws {
        let corpus = try loadCorpus()
        let canonical = Set(LightingCondition.allCases.map(\.rawValue))

        for testCase in corpus.cases {
            for label in ["weights", "target"] {
                let dict = label == "weights" ? testCase.weights : testCase.target
                for key in dict ?? [:] where !canonical.contains(key) {
                    XCTFail("Case \(testCase.id): non-canonical light source \(key) in \(label)")
                }
            }
            for color in testCase.palette {
                for key in color.responses ?? [:] where !canonical.contains(key) {
                    XCTFail("Case \(testCase.id), color \(color.id): non-canonical light source \(key)")
                }
            }
        }
    }

    func testCorpusPaletteIndicesAreSequentialAndExpectationsAddressThem() throws {
        let corpus = try loadCorpus()

        for testCase in corpus.cases {
            XCTAssertEqual(
                testCase.palette.map(\.index),
                Array(testCase.palette.indices),
                "Case \(testCase.id): palette entries must be indexed 0..<count in order"
            )
            let ids = testCase.palette.map(\.id)
            XCTAssertEqual(ids.count, Set(ids).count, "Case \(testCase.id): duplicate palette color ids")

            guard let selectedIndex = testCase.expected.selectedIndex else {
                XCTAssertTrue(
                    testCase.expected.noSelection == true || testCase.expected.selectedId != nil,
                    "Case \(testCase.id): expectation needs a selection or no_selection"
                )
                continue
            }
            XCTAssertTrue(
                testCase.palette.indices.contains(selectedIndex),
                "Case \(testCase.id): selected_index out of range"
            )
            XCTAssertEqual(
                testCase.palette[selectedIndex].id,
                testCase.expected.selectedId,
                "Case \(testCase.id): selected_id must match the color at selected_index"
            )
        }
    }

    // MARK: - Scorer parity (the core assertion)

    /// Every corpus case must produce exactly the expected
    /// `WeightedSquaredErrorScorer` selection: argmin of the weighted squared
    /// error with earliest-candidate tie-breaking, matching the Elixir
    /// `WeightedSquaredError` / `IlluminantMatching.best_match/4` policy.
    func testScorerSelectionsMatchCorpusExpectations() throws {
        let corpus = try loadCorpus()

        for testCase in corpus.cases {
            try assertScorerParity(testCase)
        }
    }

    private func assertScorerParity(
        _ testCase: ParityCase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let scorer = WeightedSquaredErrorScorer()
        let weights = try makeWeights(testCase.weights ?? [:], caseID: testCase.id)
        let target = try makeTarget(testCase.target ?? [:], caseID: testCase.id)

        struct Scored {
            let index: Int
            let id: Int
            let result: ScorerResult
        }
        var scored: [Scored] = []
        for (position, entry) in testCase.palette.enumerated() {
            let color = try makeColor(entry, caseID: testCase.id)
            scored.append(Scored(
                index: position,
                id: entry.id,
                result: scorer.score(candidate: color, target: target, weights: weights)
            ))
        }

        let excludedIDs = scored.filter { $0.result == .excluded }.map(\.id).sorted()
        XCTAssertEqual(
            excludedIDs,
            (testCase.expected.excludedIds ?? []).sorted(),
            "Case \(testCase.id): excluded candidates differ",
            file: file,
            line: line
        )

        var best: (index: Int, id: Int, score: Double)?
        for candidate in scored {
            guard case .score(let value) = candidate.result else { continue }
            if best == nil || value < best!.score {
                best = (candidate.index, candidate.id, value)
            }
        }

        if testCase.expected.noSelection == true {
            XCTAssertNil(
                best,
                "Case \(testCase.id): expected every candidate to be excluded, but one was rankable",
                file: file,
                line: line
            )
            return
        }

        let winner = try XCTUnwrap(best, "Case \(testCase.id): no rankable candidate", file: file, line: line)
        XCTAssertEqual(
            winner.index, testCase.expected.selectedIndex,
            "Case \(testCase.id): selected palette index differs",
            file: file, line: line
        )
        XCTAssertEqual(
            winner.id, testCase.expected.selectedId,
            "Case \(testCase.id): selected color id differs",
            file: file, line: line
        )
        if let expectedScore = testCase.expected.score {
            XCTAssertEqual(
                winner.score, expectedScore, accuracy: Self.scoreAccuracy,
                "Case \(testCase.id): selected candidate's score differs",
                file: file, line: line
            )
        }

        let tiedIDs = testCase.expected.tiedIds ?? []
        let resultsByID = Dictionary(scored.map { ($0.id, $0.result) }, uniquingKeysWith: { first, _ in first })
        for tiedID in tiedIDs {
            guard let result = resultsByID[tiedID] else {
                XCTFail(
                    "Case \(testCase.id): tied id \(tiedID) is not in the palette",
                    file: file, line: line
                )
                continue
            }
            guard case .score(let value) = result else {
                XCTFail(
                    "Case \(testCase.id): tied id \(tiedID) is excluded",
                    file: file, line: line
                )
                continue
            }
            XCTAssertEqual(
                value, winner.score, accuracy: Self.scoreAccuracy,
                "Case \(testCase.id): tied id \(tiedID) does not tie the winner's score",
                file: file, line: line
            )
        }
        if !tiedIDs.isEmpty {
            XCTAssertTrue(
                tiedIDs.contains(winner.id),
                "Case \(testCase.id): winner \(winner.id) must be a member of the tie set \(tiedIDs)",
                file: file, line: line
            )
            let tiedIndexes = scored.filter { tiedIDs.contains($0.id) }.map(\.index)
            XCTAssertEqual(
                winner.index, tiedIndexes.min(),
                "Case \(testCase.id): tie must resolve to the earliest candidate",
                file: file, line: line
            )
        }
    }

    // MARK: - Solver parity (end-to-end selection path)

    /// The full `CompositionSolver` selection path (the optimized fast path
    /// used in production) must agree with the corpus for every case whose
    /// target provides all active channels.
    func testSolverSelectionPathMatchesCorpusExpectations() throws {
        let corpus = try loadCorpus()

        for testCase in corpus.cases {
            let weights = try makeWeights(testCase.weights ?? [:], caseID: testCase.id)
            let target = try makeTarget(testCase.target ?? [:], caseID: testCase.id)

            // The solver requires a source grid per active condition; cases
            // whose target omits one exercise scorer-only policy.
            let active = weights.activeEntries.map(\.condition)
            guard active.allSatisfy({ target.value(for: $0) != nil }) else { continue }

            var grids: [LightingCondition: BrightnessGrid] = [:]
            for condition in active {
                grids[condition] = BrightnessGrid(
                    width: 1,
                    height: 1,
                    fill: target.value(for: condition) ?? 0
                )
            }
            let palette = try testCase.palette.map { try makeColor($0, caseID: testCase.id) }

            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: grids,
                weights: weights
            )

            XCTAssertEqual(
                result.excludedCandidateCount,
                (testCase.expected.excludedIds ?? []).count,
                "Case \(testCase.id): solver excluded-candidate count differs"
            )

            if testCase.expected.noSelection == true {
                XCTAssertNil(
                    result.colorIndices.first ?? nil,
                    "Case \(testCase.id): solver matched a cell that has no eligible candidate"
                )
                continue
            }

            XCTAssertEqual(
                result.colorIndices.first ?? -1,
                testCase.expected.selectedIndex,
                "Case \(testCase.id): solver selected palette index differs"
            )
            if let expectedScore = testCase.expected.score {
                XCTAssertEqual(
                    result.error(x: 0, y: 0),
                    expectedScore,
                    accuracy: Self.scoreAccuracy,
                    "Case \(testCase.id): solver per-cell error differs"
                )
            }
        }
    }

    // MARK: - Fixture → domain conversion

    private func condition(for key: String, caseID: String) throws -> LightingCondition {
        guard let condition = LightingCondition(rawValue: key) else {
            throw ParityFixtureError(message: "Case \(caseID): unknown light source \(key)")
        }
        return condition
    }

    private func makeWeights(_ dict: [String: Double], caseID: String) throws -> ChannelWeights {
        var values: [LightingCondition: Double] = [:]
        for (key, value) in dict {
            values[try condition(for: key, caseID: caseID)] = value
        }
        return ChannelWeights(
            white: values[.white] ?? 0,
            red: values[.red] ?? 0,
            green: values[.green] ?? 0,
            blue: values[.blue] ?? 0,
            lps: values[.lps] ?? 0
        )
    }

    private func makeTarget(_ dict: [String: Double], caseID: String) throws -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in dict {
            brightness[try condition(for: key, caseID: caseID)] = value
        }
        return TargetResponseVector(brightness)
    }

    private func makeColor(_ entry: ParityColor, caseID: String) throws -> PaletteColor {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, value) in entry.responses ?? [:] {
            responses[try condition(for: key, caseID: caseID)] = IlluminationResponse(brightness: value)
        }

        let rgb: RGBColor
        if let dto = entry.rgb {
            rgb = RGBColor(
                red: UInt8(clamping: dto.r),
                green: UInt8(clamping: dto.g),
                blue: UInt8(clamping: dto.b)
            )
        } else if let parsed = RGBColor(hex: entry.hex) {
            rgb = parsed
        } else {
            throw ParityFixtureError(
                message: "Case \(caseID): color \(entry.id) has neither usable rgb nor hex"
            )
        }

        return PaletteColor(
            id: entry.id,
            name: entry.name,
            hex: entry.hex,
            rgb: rgb,
            responses: responses
        )
    }
}
