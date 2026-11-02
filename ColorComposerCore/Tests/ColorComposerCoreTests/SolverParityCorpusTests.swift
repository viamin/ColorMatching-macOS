import XCTest
@testable import ColorComposerCore

/// Replays the solver parity corpus committed by the `color_matching` backend
/// (issue #39; corpus produced upstream by `ColorMatching.Parity.Corpus`,
/// `mix parity.generate`) against `WeightedSquaredErrorScorer` and
/// `CompositionSolver`, so silent divergence in scoring, missing-measurement
/// exclusion, tie-breaking, or channel weighting is caught.
///
/// The corpus is loaded from the fixture committed next to this test file;
/// set `PARITY_CORPUS_PATH` to replay a freshly generated corpus from a
/// `color_matching` checkout instead (see docs/solver-parity-corpus.md).
final class SolverParityCorpusTests: XCTestCase {
    private enum CorpusError: Error, LocalizedError {
        case missingFixture(String)
        case unparseableHex(String)

        var errorDescription: String? {
            switch self {
            case .missingFixture(let path): return "Parity corpus fixture missing at \(path)"
            case .unparseableHex(let hex): return "Corpus palette entry carries unparseable hex \(hex)"
            }
        }
    }

    // MARK: - Corpus wire format

    private struct ParityCorpus: Decodable {
        let algorithmVersion: Int
        let scorer: String
        let selection: String
        let missingPolicy: String
        let lightSources: [String]
        let scenarios: [Scenario]

        struct Scenario: Decodable {
            let id: String
            let description: String
            let weights: [String: Double]
            let target: Entry
            let palette: [Entry]
            let expected: Expected
        }

        struct Entry: Decodable {
            let index: Int?
            let hexColor: String
            let channels: [String: Double]
        }

        struct Expected: Decodable {
            let scores: [ScoredEntry]
            let selectedIndex: Int?
            let selectedHexColor: String?
            let error: Double?
            let tieBroke: Bool?
            let tiedIndices: [Int]
        }

        struct ScoredEntry: Decodable {
            let index: Int
            let score: Score
        }

        enum Score: Equatable, Decodable {
            case value(Double)
            case excluded

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let value = try? container.decode(Double.self) {
                    self = .value(value)
                } else if let string = try? container.decode(String.self), string == "excluded" {
                    self = .excluded
                } else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Corpus score must be a number or \"excluded\""
                    )
                }
            }
        }
    }

    private struct LoadedScenario {
        let id: String
        let weights: ChannelWeights
        let target: TargetResponseVector
        let palette: [PaletteColor]
        let expected: ParityCorpus.Expected
        let rawWeights: [String: Double]
    }

    // MARK: - Fixtures

    private static let expectedScenarioIDs = [
        "distinct-errors",
        "tie-symmetric-around-target",
        "tie-duplicate-vectors",
        "tie-three-way-on-lps",
        "missing-candidate-excluded",
        "missing-target-excluded",
        "zero-weight-channel-missing",
        "all-excluded",
        "single-channel-lps",
        "exact-match-zero-error",
        "unknown-weight-ignored",
        "mixed-large-palette",
    ]

    private func loadCorpus() throws -> ParityCorpus {
        let url = try Self.corpusURL()
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(ParityCorpus.self, from: data)
        } catch {
            XCTFail("Parity corpus at \(url.path) failed to decode: \(error)")
            throw error
        }
    }

    private static func corpusURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["PARITY_CORPUS_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ParityCorpus/corpus.json")
    }

    private func loadScenarios() throws -> [LoadedScenario] {
        let corpus = try loadCorpus()
        return try corpus.scenarios.map { scenario in
            LoadedScenario(
                id: scenario.id,
                weights: Self.channelWeights(scenario.weights),
                target: Self.targetVector(scenario.target),
                palette: try Self.paletteColors(scenario.palette),
                expected: scenario.expected,
                rawWeights: scenario.weights
            )
        }
    }

    // MARK: - Corpus → domain conversion

    private static func channelWeights(_ raw: [String: Double]) -> ChannelWeights {
        func weight(_ condition: LightingCondition) -> Double { raw[condition.rawValue] ?? 0 }
        return ChannelWeights(
            white: weight(.white),
            red: weight(.red),
            green: weight(.green),
            blue: weight(.blue),
            lps: weight(.lps)
        )
    }

    private static func targetVector(_ entry: ParityCorpus.Entry) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in entry.channels {
            if let condition = LightingCondition(rawValue: key) {
                brightness[condition] = value
            }
        }
        return TargetResponseVector(brightness)
    }

    private static func paletteColors(_ entries: [ParityCorpus.Entry]) throws -> [PaletteColor] {
        try entries.map { entry in
            guard let rgb = RGBColor(hex: entry.hexColor) else {
                throw CorpusError.unparseableHex(entry.hexColor)
            }
            var responses: [LightingCondition: IlluminationResponse] = [:]
            for (key, value) in entry.channels {
                if let condition = LightingCondition(rawValue: key) {
                    responses[condition] = IlluminationResponse(brightness: value)
                }
            }
            return PaletteColor(
                id: entry.index ?? 0,
                hex: entry.hexColor,
                rgb: rgb,
                responses: responses
            )
        }
    }

    private func earliestWinsSelection(
        _ scenario: LoadedScenario,
        scorer: WeightedSquaredErrorScorer
    ) -> (selectedIndex: Int?, scores: [Int: Double]) {
        var bestIndex: Int?
        var bestScore = Double.infinity
        var scores: [Int: Double] = [:]
        for (index, candidate) in scenario.palette.enumerated() {
            guard case .score(let value) = scorer.score(
                candidate: candidate,
                target: scenario.target,
                weights: scenario.weights
            ) else { continue }
            scores[index] = value
            if value < bestScore {
                bestScore = value
                bestIndex = index
            }
        }
        return (bestIndex, scores)
    }

    private func excludedCount(_ expected: ParityCorpus.Expected) -> Int {
        expected.scores.reduce(0) { count, entry in
            if case .excluded = entry.score { return count + 1 }
            return count
        }
    }

    // MARK: - Metadata contract

    func testCorpusMetadataMatchesSwiftSolverContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1, "Swift scorer tracks corpus algorithm_version")
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.allCases.map(\.rawValue))
    }

    func testCorpusScenarioIDsAreStable() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(
            corpus.scenarios.map(\.id),
            Self.expectedScenarioIDs,
            "Corpus scenarios changed; refresh the fixture per docs/solver-parity-corpus.md"
        )
    }

    // MARK: - Per-candidate scores (ties, exclusions, weight handling)

    func testPerCandidateScoresMatchCorpusExactly() throws {
        let scorer = WeightedSquaredErrorScorer()
        let scenarios = try loadScenarios()

        for scenario in scenarios {
            for scored in scenario.expected.scores {
                let candidate = scenario.palette[scored.index]
                let result = scorer.score(
                    candidate: candidate,
                    target: scenario.target,
                    weights: scenario.weights
                )

                switch (result, scored.score) {
                case (.excluded, .excluded):
                    break
                case (.score(let got), .value(let expected)):
                    XCTAssertEqual(
                        got,
                        expected,
                        accuracy: 1e-12,
                        "\(scenario.id)[\(scored.index)]: score mismatch"
                    )
                default:
                    XCTFail("\(scenario.id)[\(scored.index)]: expected \(scored.score), got \(result)")
                }
            }
        }
    }

    func testSelectionMatchesCorpusIncludingTieCases() throws {
        let scorer = WeightedSquaredErrorScorer()
        let scenarios = try loadScenarios()

        for scenario in scenarios {
            let (selectedIndex, scores) = earliestWinsSelection(scenario, scorer: scorer)

            XCTAssertEqual(
                selectedIndex,
                scenario.expected.selectedIndex,
                "\(scenario.id): selected index"
            )

            if let selectedIndex {
                XCTAssertEqual(
                    scenario.palette[selectedIndex].hex,
                    scenario.expected.selectedHexColor,
                    "\(scenario.id): selected hex color"
                )
                if let expectedError = scenario.expected.error {
                    XCTAssertEqual(
                        scores[selectedIndex] ?? .nan,
                        expectedError,
                        accuracy: 1e-12,
                        "\(scenario.id): selected error"
                    )
                } else {
                    XCTFail("\(scenario.id): expected an error alongside selection")
                }

                let tiedIndices = scores
                    .filter { $0.value == scores[selectedIndex] }
                    .map(\.key)
                    .sorted()
                XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, "\(scenario.id): tied indices")
                XCTAssertEqual(
                    tiedIndices.count > 1,
                    scenario.expected.tieBroke ?? false,
                    "\(scenario.id): tie_broke"
                )
            } else {
                XCTAssertNil(scenario.expected.selectedHexColor, "\(scenario.id)")
                XCTAssertNil(scenario.expected.error, "\(scenario.id)")
                XCTAssertEqual(scenario.expected.tiedIndices, [], "\(scenario.id)")
            }
        }
    }

    func testUnknownWeightKeysAreIgnored() throws {
        let scenarios = try loadScenarios()
        let unknown = try XCTUnwrap(scenarios.first { $0.id == "unknown-weight-ignored" })
        let distinct = try XCTUnwrap(scenarios.first { $0.id == "distinct-errors" })

        XCTAssertTrue(
            unknown.rawWeights.keys.contains("ultraviolet"),
            "corpus scenario should carry an unknown light source"
        )
        XCTAssertEqual(unknown.weights, distinct.weights)
    }

    // MARK: - Solver-level replay (fast path, earliest-wins ties)

    func testSolverFastPathSelectsCorpusExpectedIndices() throws {
        let scenarios = try loadScenarios()

        for scenario in scenarios {
            let active = scenario.weights.activeEntries.map(\.condition)
            let replayable = active.allSatisfy { scenario.target.value(for: $0) != nil }
            guard replayable else {
                XCTAssertTrue(
                    scenario.expected.selectedIndex == nil
                        && scenario.id == "missing-target-excluded",
                    "\(scenario.id): only the missing-target scenario may skip solver replay"
                )
                continue
            }

            var grids: [LightingCondition: BrightnessGrid] = [:]
            for condition in active {
                let value = try XCTUnwrap(scenario.target.value(for: condition), scenario.id)
                grids[condition] = BrightnessGrid(width: 1, height: 1, values: [value])
            }

            let result = try CompositionSolver().solve(
                palette: scenario.palette,
                sourceGrids: grids,
                weights: scenario.weights
            )

            XCTAssertEqual(result.cellCount, 1, scenario.id)
            XCTAssertEqual(
                result.colorIndices.first ?? nil,
                scenario.expected.selectedIndex,
                "\(scenario.id): solver selection"
            )

            if let expectedError = scenario.expected.error {
                XCTAssertEqual(
                    try XCTUnwrap(result.errors.first),
                    expectedError,
                    accuracy: 1e-12,
                    "\(scenario.id): solver error"
                )
            } else {
                XCTAssertTrue(
                    try XCTUnwrap(result.errors.first).isInfinite,
                    "\(scenario.id): no selection must record infinite error"
                )
            }

            XCTAssertEqual(
                result.excludedCandidateCount,
                excludedCount(scenario.expected),
                "\(scenario.id): excluded candidate count"
            )
        }
    }
}
