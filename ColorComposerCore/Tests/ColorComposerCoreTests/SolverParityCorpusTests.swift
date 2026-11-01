import XCTest
@testable import ColorComposerCore

/// Solver-parity replay of the golden-vector corpus committed from
/// `viamin/color_matching` (parity corpus PR #111; upstream path
/// `priv/parity/v1/corpus.json`).
///
/// The corpus is the parity contract shared with the Elixir
/// `ColorMatching.WeightedSquaredError` solver: every scenario is replayed
/// through `WeightedSquaredErrorScorer` with the server's earliest-index-wins
/// selection policy, and per-candidate scores must match **exactly** (all
/// corpus numbers are dyadic rationals, so IEEE 754 equality is deterministic
/// across languages and summation orders — mirroring the upstream
/// `ColorMatching.Parity.CorpusTest`, which also asserts exact equality).
///
/// Any mismatch here means client and server would pick different inks for the
/// same inputs. See `docs/solver-parity-corpus.md` for how to refresh the
/// corpus.
final class SolverParityCorpusTests: XCTestCase {
    private static let corpusURL = locateCorpus()

    private var scorer: WeightedSquaredErrorScorer!

    override func setUp() {
        super.setUp()
        scorer = WeightedSquaredErrorScorer()
    }

    // MARK: - Corpus fixture

    func testCorpusMetadataMatchesSharedContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1, "corpus algorithm_version must match the parity contract the app implements")
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
    }

    func testCorpusContainsIntentionalTieAndNoSelectionScenarios() throws {
        let corpus = try loadCorpus()

        let tied = corpus.scenarios.filter { $0.expected.tieBroke == true }
        let noSelection = corpus.scenarios.filter { $0.expected.selectedIndex == nil }

        XCTAssertGreaterThanOrEqual(tied.count, 1, "corpus must keep at least one intentional tie scenario")
        XCTAssertGreaterThanOrEqual(noSelection.count, 1, "corpus must keep at least one all-excluded scenario")
        XCTAssertGreaterThanOrEqual(corpus.scenarios.count, 12, "corpus refresh must not drop scenarios")
    }

    // MARK: - Full replay

    func testReplaysEveryScenarioWithExactAgreement() throws {
        let corpus = try loadCorpus()

        XCTAssertGreaterThanOrEqual(corpus.scenarios.count, 12, "parity corpus is missing scenarios; see docs/solver-parity-corpus.md to refresh it")

        for scenario in corpus.scenarios {
            let outcome = replay(scenario)

            assertScores(outcome, match: scenario.expected, id: scenario.id)
            assertSelection(outcome, matches: scenario.expected, scenario: scenario)
            assertTieEvidence(outcome, matches: scenario.expected, id: scenario.id)
        }
    }

    func testTieScenariosSelectEarliestTiedIndex() throws {
        let corpus = try loadCorpus()
        let tied = corpus.scenarios.filter { $0.expected.tieBroke == true }

        XCTAssertGreaterThanOrEqual(tied.count, 3, "expected the committed tie scenarios to survive a corpus refresh")

        for scenario in tied {
            let outcome = replay(scenario)
            XCTAssertGreaterThan(outcome.tiedIndices.count, 1, scenario.id)
            XCTAssertEqual(outcome.tiedIndices.first, outcome.selectedIndex, "\(scenario.id): earliest tied index must win")
            XCTAssertEqual(outcome.selectedIndex, scenario.expected.selectedIndex, scenario.id)
        }
    }

    func testExcludedScenariosProduceNoSelection() throws {
        let corpus = try loadCorpus()
        let excluded = corpus.scenarios.filter { $0.expected.selectedIndex == nil }

        XCTAssertGreaterThanOrEqual(excluded.count, 2, "expected the committed all-excluded scenarios to survive a corpus refresh")

        for scenario in excluded {
            let outcome = replay(scenario)
            XCTAssertNil(outcome.selectedIndex, "\(scenario.id): every candidate must be excluded")
            XCTAssertTrue(outcome.tiedIndices.isEmpty, scenario.id)
            XCTAssertTrue(outcome.scores.allSatisfy { $0 == .excluded }, scenario.id)
        }
    }

    func testUnknownWeightKeysAreIgnored() throws {
        let corpus = try loadCorpus()
        let scenario = try XCTUnwrap(
            corpus.scenarios.first { $0.id == "unknown-weight-ignored" },
            "corpus is missing the unknown-weight scenario; refresh it per docs/solver-parity-corpus.md"
        )

        let outcome = replay(scenario)
        let expected = scenario.expected

        XCTAssertEqual(outcome.selectedIndex, expected.selectedIndex)
        if let selected = outcome.selectedIndex, let expectedError = expected.error {
            XCTAssertEqual(outcome.scores[selected], .score(expectedError))
        }
    }

    /// The production `CompositionSolver` fast path (contiguous-array,
    /// earliest-wins, parallelized) must land on the same selection and error
    /// as the scorer-level replay for every scenario the app can express
    /// (target fully measured for the active channels).
    func testSolverFastPathAgreesWithCorpusSelection() throws {
        let corpus = try loadCorpus()
        let solvable = corpus.scenarios.filter { scenario in
            let weights = decodeWeights(scenario.weights)
            return weights.activeConditions.allSatisfy { scenario.target.channels[$0.rawValue] != nil }
        }

        XCTAssertGreaterThanOrEqual(solvable.count, 9, "expected the fully-measured corpus scenarios to survive a refresh")
        let solver = CompositionSolver(scorer: WeightedSquaredErrorScorer())

        for scenario in solvable {
            let weights = decodeWeights(scenario.weights)
            let palette = scenario.palette.sorted { $0.index ?? 0 < $1.index ?? 0 }.map(domainColor)
            var sourceGrids: [LightingCondition: BrightnessGrid] = [:]
            for (condition, _) in weights.activeEntries {
                let value = scenario.target.channels[condition.rawValue] ?? 0
                sourceGrids[condition] = BrightnessGrid(width: 1, height: 1, fill: value)
            }

            let result = try solver.solve(palette: palette, sourceGrids: sourceGrids, weights: weights)

            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
            if scenario.expected.selectedIndex != nil {
                XCTAssertEqual(result.error(x: 0, y: 0), scenario.expected.error, scenario.id)
            } else {
                XCTAssertEqual(result.error(x: 0, y: 0), Double.infinity, scenario.id)
            }
            let expectedExcluded = scenario.expected.scores.filter { $0.score == .excluded }.count
            XCTAssertEqual(result.excludedCandidateCount, expectedExcluded, scenario.id)
        }
    }

    // MARK: - Replay harness

    private struct ReplayOutcome {
        let scores: [ScorerResult]
        let selectedIndex: Int?
        let error: Double?
        let tiedIndices: [Int]
    }

    /// Scores every palette candidate and applies the shared
    /// earliest-index-wins selection policy over the scorer results.
    private func replay(_ scenario: ParityScenario) -> ReplayOutcome {
        let weights = decodeWeights(scenario.weights)
        let target = domainTarget(scenario.target)
        let palette = scenario.palette
            .sorted { $0.index ?? 0 < $1.index ?? 0 }
            .map(domainColor)

        var scores: [ScorerResult] = []
        var selectedIndex: Int?
        var bestScore = Double.infinity

        for (index, color) in palette.enumerated() {
            let result = scorer.score(candidate: color, target: target, weights: weights)
            scores.append(result)
            if case .score(let value) = result, value < bestScore {
                bestScore = value
                selectedIndex = index
            }
        }

        let tiedIndices: [Int]
        if let selectedIndex {
            tiedIndices = scores.indices.compactMap { index in
                guard case .score(let value) = scores[index], value == bestScore else { return nil }
                return index
            }
        } else {
            tiedIndices = []
        }

        return ReplayOutcome(
            scores: scores,
            selectedIndex: selectedIndex,
            error: selectedIndex == nil ? nil : bestScore,
            tiedIndices: tiedIndices
        )
    }

    /// Decodes corpus weights into `ChannelWeights`, dropping keys that are
    /// not known light sources — mirroring the Elixir `filter_weights/1`
    /// (unknown keys such as `ultraviolet` are silently ignored).
    private func decodeWeights(_ raw: [String: Double]) -> ChannelWeights {
        func value(_ condition: LightingCondition) -> Double {
            raw[condition.rawValue] ?? 0
        }
        return ChannelWeights(
            white: value(.white),
            red: value(.red),
            green: value(.green),
            blue: value(.blue),
            lps: value(.lps)
        )
    }

    /// Absent channel keys are missing measurements (never zero brightness);
    /// unknown light-source keys are dropped.
    private func domainColor(_ vector: ParityVector) -> PaletteColor {
        PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor) ?? RGBColor(red: 0, green: 0, blue: 0),
            responses: responses(vector.channels)
        )
    }

    private func domainTarget(_ vector: ParityVector) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in vector.channels {
            if let condition = LightingCondition(rawValue: key) {
                brightness[condition] = value
            }
        }
        return TargetResponseVector(brightness)
    }

    private func responses(_ channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, value) in channels {
            if let condition = LightingCondition(rawValue: key) {
                responses[condition] = IlluminationResponse(brightness: value)
            }
        }
        return responses
    }

    // MARK: - Assertions (mirroring ColorMatching.Parity.CorpusTest)

    private func assertScores(_ outcome: ReplayOutcome, match expected: ParityExpectation, id: String) {
        XCTAssertEqual(outcome.scores.count, expected.scores.count, id)

        let expectedByIndex = expected.scores.sorted { $0.index < $1.index }
        for (index, expectedScore) in expectedByIndex.enumerated() {
            let actual = index < outcome.scores.count ? outcome.scores[index] : nil
            switch (actual, expectedScore.score) {
            case (.excluded, .excluded):
                continue
            case (.score(let value), .score(let expectedValue)):
                // Exact equality is intentional: corpus values are dyadic
                // rationals, exactly representable and order-independent.
                XCTAssertEqual(value, expectedValue, "\(id): candidate \(expectedScore.index) score \(value) != \(expectedValue)")
            default:
                XCTFail("\(id): candidate \(expectedScore.index) expected \(expectedScore.score), got \(String(describing: actual))")
            }
        }
    }

    private func assertSelection(
        _ outcome: ReplayOutcome,
        matches expected: ParityExpectation,
        scenario: ParityScenario
    ) {
        guard let selectedIndex = expected.selectedIndex else {
            XCTAssertNil(outcome.selectedIndex, "\(scenario.id): expected no selection, got \(String(describing: outcome.selectedIndex))")
            return
        }

        let palette = scenario.palette.sorted { $0.index ?? 0 < $1.index ?? 0 }
        XCTAssertNotNil(outcome.selectedIndex, scenario.id)
        XCTAssertEqual(outcome.selectedIndex, selectedIndex, "\(scenario.id): selected the wrong palette index")
        let selectedHex = palette.indices.contains(selectedIndex) ? palette[selectedIndex].hexColor : nil
        XCTAssertEqual(selectedHex, expected.selectedHexColor, scenario.id)
        XCTAssertEqual(outcome.error, expected.error, scenario.id)
    }

    private func assertTieEvidence(_ outcome: ReplayOutcome, matches expected: ParityExpectation, id: String) {
        if outcome.selectedIndex == nil {
            XCTAssertNil(expected.tieBroke, id)
            XCTAssertTrue(expected.tiedIndices.isEmpty, id)
            return
        }

        XCTAssertEqual(outcome.tiedIndices, expected.tiedIndices, id)
        XCTAssertEqual(expected.tieBroke, outcome.tiedIndices.count > 1, id)
        XCTAssertEqual(outcome.tiedIndices.first, expected.selectedIndex, id)
    }

    // MARK: - Corpus loading

    private func loadCorpus(file: StaticString = #filePath, line: UInt = #line) throws -> ParityCorpus {
        let url = try XCTUnwrap(Self.corpusURL, file: file, line: line)
        do {
            let data = try Data(contentsOf: url)
            return try Self.decoder.decode(ParityCorpus.self, from: data)
        } catch {
            XCTFail("parity corpus at \(url.path) is unreadable or malformed: \(error). See docs/solver-parity-corpus.md to refresh it.", file: file, line: line)
            throw error
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// Bundle resource first (if the fixture is declared in Package.swift as a
    /// resource), then the committed source tree next to the test target.
    private static func locateCorpus() -> URL? {
        if let bundled = Bundle(for: SolverParityCorpusTests.self).url(forResource: "corpus", withExtension: "json") {
            return bundled
        }
        let sourceTree = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/ColorComposerCoreTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("ParityCorpus", isDirectory: true)
            .appendingPathComponent("corpus.json")
        return FileManager.default.fileExists(atPath: sourceTree.path) ? sourceTree : nil
    }
}

// MARK: - Wire models (corpus JSON)

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let description: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpectation
}

private struct ParityVector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpectation: Decodable {
    let scores: [ParityScore]
    let selectedIndex: Int?
    let selectedHexColor: String?
    let error: Double?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ParityScoreValue
}

/// A score is either a JSON number or the literal string `"excluded"`.
private enum ParityScoreValue: Decodable, Equatable {
    case score(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self), string == "excluded" {
            self = .excluded
        } else {
            self = .score(try container.decode(Double.self))
        }
    }
}
