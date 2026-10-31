import XCTest
@testable import ColorComposerCore

/// Solver parity against the committed corpus.
///
/// Loads `Fixtures/solver_parity_corpus.json` (schema and refresh
/// instructions in `docs/solver-parity-corpus.md`) and asserts that
/// `WeightedSquaredErrorScorer` — the Swift mirror of the Elixir
/// `ColorMatching.WeightedSquaredError` — selects exactly the expected
/// palette color for every target vector, including ties (earliest palette
/// entry wins) and exclusions (a candidate missing a measurement for any
/// weight > 0 condition is excluded; a measured zero is *not* missing).
///
/// Selections are asserted at two levels:
/// - scorer level: the raw `CompositionScorer` ranking loop, and
/// - solver level: `CompositionSolver`'s production fast path, which also
///   pins tie-breaking, `excludedCandidateCount`, per-cell error, and
///   unmatched-cell accounting.
final class SolverParityCorpusTests: XCTestCase {
    // MARK: - Corpus wire format (schema_version 1)

    private struct ParityCorpus: Codable {
        let schemaVersion: Int
        let cases: [ParityCase]
    }

    private struct ParityCase: Codable {
        let id: String
        let description: String?
        let weights: [String: Double]
        let palette: [ParityColor]
        let targets: [[String: Double]]
        let expectedSelections: [Int?]
        let expectedScores: [Double?]
        let expectedExcludedCount: Int
    }

    private struct ParityColor: Codable {
        let id: Int
        let hex: String
        let responses: [String: Double]
    }

    // MARK: - Corpus loading

    private static let corpusURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/solver_parity_corpus.json")

    private func loadCorpus(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ParityCorpus {
        let data: Data
        do {
            data = try Data(contentsOf: Self.corpusURL)
        } catch {
            XCTFail(
                "Parity corpus fixture is missing or unreadable at \(Self.corpusURL.path); "
                    + "see docs/solver-parity-corpus.md for the committed location",
                file: file,
                line: line
            )
            throw error
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            let corpus = try decoder.decode(ParityCorpus.self, from: data)
            XCTAssertGreaterThanOrEqual(corpus.schemaVersion, 1, "Unsupported corpus schema", file: file, line: line)
            XCTAssertFalse(corpus.cases.isEmpty, "Parity corpus must contain at least one case", file: file, line: line)
            return corpus
        } catch {
            XCTFail("Parity corpus does not match schema_version 1: \(error)", file: file, line: line)
            throw error
        }
    }

    // MARK: - Corpus → domain conversion

    private struct CorpusFormatError: Error {}

    private func condition(
        _ key: String,
        caseID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> LightingCondition {
        guard let condition = LightingCondition(rawValue: key) else {
            XCTFail("Case '\(caseID)': unknown lighting-condition key '\(key)'", file: file, line: line)
            throw CorpusFormatError()
        }
        return condition
    }

    private func channelWeights(_ dict: [String: Double], caseID: String) throws -> ChannelWeights {
        var weights = ChannelWeights()
        for (key, value) in dict {
            switch try condition(key, caseID: caseID) {
            case .white: weights.white = value
            case .red: weights.red = value
            case .green: weights.green = value
            case .blue: weights.blue = value
            case .lps: weights.lps = value
            }
        }
        return weights
    }

    private func domainColor(_ entry: ParityColor, caseID: String) throws -> PaletteColor {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, brightness) in entry.responses {
            responses[try condition(key, caseID: caseID)] = IlluminationResponse(brightness: brightness)
        }
        let rgb = try XCTUnwrap(RGBColor(hex: entry.hex), "Case '\(caseID)': hex '\(entry.hex)' does not parse")
        return PaletteColor(id: entry.id, hex: entry.hex, rgb: rgb, responses: responses)
    }

    private func targetVector(_ dict: [String: Double], caseID: String) throws -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in dict {
            brightness[try condition(key, caseID: caseID)] = value
        }
        return TargetResponseVector(brightness)
    }

    // MARK: - Parity assertions

    func testSolverSelectionsMatchCorpusExactly() throws {
        let corpus = try loadCorpus()
        for parityCase in corpus.cases {
            try assertSolverParity(parityCase)
        }
    }

    func testScorerRankingMatchesCorpusExactly() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for parityCase in corpus.cases {
            let weights = try channelWeights(parityCase.weights, caseID: parityCase.id)
            let palette = try parityCase.palette.map { try domainColor($0, caseID: parityCase.id) }

            for (index, target) in parityCase.targets.enumerated() {
                let vector = try targetVector(target, caseID: parityCase.id)

                // Earliest-wins argmin exactly as the Elixir solver ranks.
                var bestID: Int?
                var bestScore = Double.infinity
                for color in palette {
                    guard case .score(let score) = scorer.score(candidate: color, target: vector, weights: weights) else {
                        continue
                    }
                    if score < bestScore {
                        bestScore = score
                        bestID = color.id
                    }
                }

                XCTAssertEqual(
                    bestID,
                    parityCase.expectedSelections[index],
                    "Case '\(parityCase.id)' target \(index): scorer-level selection"
                )
                if let expected = parityCase.expectedScores[index] {
                    XCTAssertEqual(bestScore, expected, accuracy: 1e-9, "Case '\(parityCase.id)' target \(index): scorer-level score")
                } else {
                    XCTAssertTrue(bestScore.isInfinite, "Case '\(parityCase.id)' target \(index): expected no eligible candidate")
                }
            }
        }
    }

    private func assertSolverParity(_ parityCase: ParityCase) throws {
        let caseID = "Case '\(parityCase.id)'"
        let weights = try channelWeights(parityCase.weights, caseID: parityCase.id)
        let palette = try parityCase.palette.map { try domainColor($0, caseID: parityCase.id) }
        XCTAssertFalse(palette.isEmpty, "\(caseID): palette must not be empty")
        XCTAssertFalse(weights.activeConditions.isEmpty, "\(caseID): at least one weight must be > 0")

        XCTAssertEqual(
            parityCase.expectedSelections.count, parityCase.targets.count,
            "\(caseID): expected_selections must align with targets"
        )
        XCTAssertEqual(
            parityCase.expectedScores.count, parityCase.targets.count,
            "\(caseID): expected_scores must align with targets"
        )

        let paletteIDs = Set(parityCase.palette.map(\.id))
        for expectedID in parityCase.expectedSelections {
            if let expectedID {
                XCTAssertTrue(paletteIDs.contains(expectedID), "\(caseID): expected selection \(expectedID) is not in the palette")
            }
        }

        // One grid per active condition, one column per target.
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for condition in weights.activeConditions {
            let values = try parityCase.targets.map { target -> Double in
                try XCTUnwrap(
                    try targetVector(target, caseID: parityCase.id).value(for: condition),
                    "\(caseID): target missing active condition '\(condition.rawValue)'"
                )
            }
            grids[condition] = BrightnessGrid(width: parityCase.targets.count, height: 1, values: values)
        }

        // Production path: default scorer, no dithering → solveFast.
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)

        XCTAssertEqual(
            result.excludedCandidateCount, parityCase.expectedExcludedCount,
            "\(caseID): excludedCandidateCount"
        )

        for (index, expectedID) in parityCase.expectedSelections.enumerated() {
            let selectedID = result.colorIndex(x: index, y: 0).map { palette[$0].id }
            XCTAssertEqual(selectedID, expectedID, "\(caseID) target \(index): selected palette id")

            if let expectedScore = parityCase.expectedScores[index] {
                let error = result.error(x: index, y: 0)
                XCTAssertFalse(error.isInfinite, "\(caseID) target \(index): expected a matched cell")
                XCTAssertEqual(error, expectedScore, accuracy: 1e-9, "\(caseID) target \(index): weighted squared error")
            } else {
                XCTAssertTrue(
                    result.error(x: index, y: 0).isInfinite,
                    "\(caseID) target \(index): expected an unmatched cell (infinite error)"
                )
            }
        }

        let expectedUnmatched = parityCase.expectedSelections.lazy.filter { $0 == nil }.count
        XCTAssertEqual(result.unmatchedCellCount, expectedUnmatched, "\(caseID): unmatched cell count")
    }

    // MARK: - Corpus hygiene

    /// Guards the corpus against drift: the parity behaviors called out in
    /// issue #39 (ties, exclusions, zero-weight channels, fractional weights,
    /// all-excluded targets) must stay covered, or the exact-match tests above
    /// silently lose their teeth when the corpus is refreshed upstream.
    func testCorpusKeepsCoveringTiesExclusionsAndWeightHandling() throws {
        let corpus = try loadCorpus()
        let ids = corpus.cases.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Corpus case ids must be unique")

        var coversTie = false
        var coversExclusion = false
        var coversUnmatched = false
        var coversZeroWeightChannel = false
        var coversFractionalWeights = false

        for parityCase in corpus.cases {
            let weights = try channelWeights(parityCase.weights, caseID: parityCase.id)
            let palette = try parityCase.palette.map { try domainColor($0, caseID: parityCase.id) }

            if parityCase.expectedSelections.contains(where: { $0 == nil }) {
                coversUnmatched = true
            }
            if parityCase.expectedExcludedCount > 0 {
                coversExclusion = true
            }
            if weights.white.rounded() != weights.white || weights.red.rounded() != weights.red
                || weights.green.rounded() != weights.green || weights.blue.rounded() != weights.blue
                || weights.lps.rounded() != weights.lps
            {
                coversFractionalWeights = true
            }
            let targetKeys = Set(parityCase.targets.flatMap(\.keys))
            let zeroWeightConditions = try targetKeys
                .map { try condition($0, caseID: parityCase.id) }
                .filter { weights.weight(for: $0) == 0 }
            if !zeroWeightConditions.isEmpty {
                coversZeroWeightChannel = true
            }

            // A tie exists when two or more eligible candidates share the
            // minimum score for some target (the winner must then be the
            // earliest one, asserted above).
            let scorer = WeightedSquaredErrorScorer()
            for target in parityCase.targets {
                let vector = try targetVector(target, caseID: parityCase.id)
                let scores = palette.compactMap { color -> Double? in
                    guard case .score(let score) = scorer.score(
                        candidate: color, target: vector, weights: weights
                    ) else { return nil }
                    return score
                }
                guard let minimum = scores.min() else { continue }
                if scores.filter({ abs($0 - minimum) < 1e-12 }).count >= 2 {
                    coversTie = true
                }
            }
        }

        XCTAssertTrue(coversTie, "Corpus must keep at least one tie case")
        XCTAssertTrue(coversExclusion, "Corpus must keep at least one exclusion case")
        XCTAssertTrue(coversUnmatched, "Corpus must keep at least one all-candidates-excluded case")
        XCTAssertTrue(coversZeroWeightChannel, "Corpus must keep at least one zero-weight-channel case")
        XCTAssertTrue(coversFractionalWeights, "Corpus must keep at least one fractional-weight case")
    }
}
