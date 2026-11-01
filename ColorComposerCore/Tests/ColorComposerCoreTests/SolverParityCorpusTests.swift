import Foundation
import XCTest
@testable import ColorComposerCore

// MARK: - Corpus wire format (viamin/color_matching priv/parity/v1/corpus.json)

/// One palette or target vector from the corpus: a channel map keyed by the
/// server's light-source strings. Absent keys mean "unmeasured", never zero.
struct ParityVector: Decodable, Equatable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

/// A per-candidate expected score: either a finite number or the string
/// `"excluded"` when the missing-measurement policy excludes the candidate.
enum ParityScore: Decodable, Equatable {
    case score(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .score(value)
        } else if let marker = try? container.decode(String.self), marker == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "score must be a number or \"excluded\""
            )
        }
    }
}

struct ParityScoreEntry: Decodable, Equatable {
    let index: Int
    let score: ParityScore
}

struct ParityExpected: Decodable, Equatable {
    let selectedIndex: Int?
    let selectedHexColor: String?
    let error: Double?
    let tieBroke: Bool?
    let tiedIndices: [Int]
    let scores: [ParityScoreEntry]
}

struct ParityScenario: Decodable, Equatable {
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpected
}

struct ParityCorpus: Decodable, Equatable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]
}

// MARK: - Corpus replay

/// Replays the committed solver parity corpus (issue #39) through
/// `WeightedSquaredErrorScorer` and `CompositionSolver`, asserting exact
/// agreement with the Elixir `ColorMatching.WeightedSquaredError` golden
/// vectors: per-candidate scores, selected color, winning error, tie sets,
/// tie-breaking, and missing-measurement exclusions.
///
/// The corpus is committed verbatim from
/// viamin/color_matching `priv/parity/v1/corpus.json` (#111) — see
/// `docs/solver-parity-corpus.md` for provenance and refresh instructions.
///
/// Intentionally exceeds the ~100-line class target: it is a data-driven
/// replay harness whose length tracks the corpus wire format, not logic that
/// would benefit from splitting across types.
final class SolverParityCorpusTests: XCTestCase {
    private static let corpusURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/parity/v1/corpus.json")

    private var loadedCorpus: ParityCorpus?

    private func loadCorpus(file: StaticString = #filePath, line: UInt = #line) throws -> ParityCorpus {
        if let loadedCorpus { return loadedCorpus }
        let data = try Data(contentsOf: Self.corpusURL)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(ParityCorpus.self, from: data)
        loadedCorpus = decoded
        return decoded
    }

    // MARK: Corpus-to-domain mapping

    private func domainColor(from vector: ParityVector) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: vector.hexColor), "unparseable hex \(vector.hexColor)")
        return PaletteColor(id: vector.index ?? 0, hex: vector.hexColor, rgb: rgb, responses: responses(vector.channels))
    }

    private func responses(_ channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        conditionValues(channels).mapValues { IlluminationResponse(brightness: $0) }
    }

    /// Canonical channels only: unknown light-source keys (e.g. `"ultraviolet"`)
    /// are ignored, mirroring the fixed channel set the corpus pins itself.
    private func conditionValues(_ channels: [String: Double]) -> [LightingCondition: Double] {
        var out: [LightingCondition: Double] = [:]
        for (key, value) in channels {
            if let condition = LightingCondition(rawValue: key) { out[condition] = value }
        }
        return out
    }

    private func channelWeights(from map: [String: Double]) -> ChannelWeights {
        var weights = ChannelWeights()
        for (key, value) in map {
            switch LightingCondition(rawValue: key) {
            case .white: weights.white = value
            case .red: weights.red = value
            case .green: weights.green = value
            case .blue: weights.blue = value
            case .lps: weights.lps = value
            case nil: break
            }
        }
        return weights
    }

    // MARK: Replay helpers

    /// Earliest-wins selection over scorer results — the client-side
    /// restatement of the corpus `selection: "earliest-index-wins"` policy.
    private func earliestWin(_ results: [ScorerResult]) -> (index: Int, score: Double)? {
        var best: (index: Int, score: Double)?
        for (index, result) in results.enumerated() {
            guard case .score(let value) = result, value < (best?.score ?? .infinity) else { continue }
            best = (index, value)
        }
        return best
    }

    /// Indices whose score sits within epsilon of the winner — the corpus tie set.
    private func tieIndices(in results: [ScorerResult], around winner: (index: Int, score: Double)) -> [Int] {
        results.indices.filter { index in
            guard case .score(let value) = results[index] else { return false }
            return abs(value - winner.score) <= 1e-12
        }
    }

    private func assertScores(
        _ results: [ScorerResult],
        match expected: ParityExpected,
        scenario: ParityScenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectedScores = Dictionary(
            expected.scores.map { ($0.index, $0.score) },
            uniquingKeysWith: { first, _ in first }
        )
        XCTAssertEqual(results.count, expected.scores.count, "[\(scenario.id)] candidate count", file: file, line: line)
        for (index, result) in results.enumerated() {
            assertScore(result, matches: expectedScores[index], candidate: index, scenario: scenario, file: file, line: line)
        }
    }

    private func assertScore(
        _ result: ScorerResult,
        matches expected: ParityScore?,
        candidate: Int,
        scenario: ParityScenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (expected, result) {
        case (.score(let expectedValue)?, .score(let actual)):
            XCTAssertEqual(actual, expectedValue, accuracy: 1e-12, "[\(scenario.id)] score of candidate \(candidate)", file: file, line: line)
        case (.excluded?, .excluded):
            break
        case (.score(let expectedValue)?, .excluded):
            XCTFail("[\(scenario.id)] candidate \(candidate) excluded, expected score \(expectedValue)", file: file, line: line)
        case (.excluded?, .score(let actual)):
            XCTFail("[\(scenario.id)] candidate \(candidate) scored \(actual), expected excluded", file: file, line: line)
        case (nil, _):
            XCTFail("[\(scenario.id)] no expected score for candidate \(candidate)", file: file, line: line)
        }
    }

    private func assertSelection(
        winner: (index: Int, score: Double)?,
        tieIndices: [Int],
        palette: [PaletteColor],
        expected: ParityExpected,
        scenario: ParityScenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard let expectedIndex = expected.selectedIndex else {
            XCTAssertNil(winner, "[\(scenario.id)] expected no selection", file: file, line: line)
            return
        }
        let win = try XCTUnwrap(winner, "[\(scenario.id)] expected selection \(expectedIndex), got none", file: file, line: line)
        XCTAssertEqual(win.index, expectedIndex, "[\(scenario.id)] selected index", file: file, line: line)
        XCTAssertEqual(tieIndices, expected.tiedIndices, "[\(scenario.id)] tied indices", file: file, line: line)
        XCTAssertEqual(expected.tieBroke, tieIndices.count > 1, "[\(scenario.id)] tie_broke flag", file: file, line: line)
        if let expectedError = expected.error {
            XCTAssertEqual(win.score, expectedError, accuracy: 1e-12, "[\(scenario.id)] winning error", file: file, line: line)
        }
        XCTAssertEqual(palette[expectedIndex].hex, expected.selectedHexColor, "[\(scenario.id)] selected hex", file: file, line: line)
    }

    // MARK: Corpus contract

    func testCorpusMetadataMatchesSupportedParityContract() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1, "a newer corpus generation needs a new fixture directory and test review")
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(Set(corpus.lightSources), Set(LightingCondition.allCases.map(\.rawValue)))
        XCTAssertGreaterThanOrEqual(corpus.scenarios.count, 12, "corpus unexpectedly small — refresh the fixture")
    }

    func testCorpusKeepsTieAndExclusionScenariosCovered() throws {
        let corpus = try loadCorpus()
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true }, "corpus lost its tie-break evidence")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil }, "corpus lost its no-selection scenario")
        XCTAssertTrue(
            corpus.scenarios.contains { $0.expected.scores.contains { $0.score == .excluded } },
            "corpus lost its exclusion evidence"
        )
    }

    // MARK: Scorer parity

    func testScorerMatchesEveryCorpusScenario() throws {
        for scenario in try loadCorpus().scenarios { try replayThroughScorer(scenario) }
    }

    private func replayThroughScorer(_ scenario: ParityScenario, file: StaticString = #filePath, line: UInt = #line) throws {
        let scorer = WeightedSquaredErrorScorer()
        let palette = try scenario.palette.map(domainColor(from:))
        let target = TargetResponseVector(conditionValues(scenario.target.channels))
        let weights = channelWeights(from: scenario.weights)

        let results = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
        let winner = earliestWin(results)
        let ties = winner.map { tieIndices(in: results, around: $0) } ?? []

        assertScores(results, match: scenario.expected, scenario: scenario, file: file, line: line)
        try assertSelection(
            winner: winner, tieIndices: ties, palette: palette,
            expected: scenario.expected, scenario: scenario, file: file, line: line
        )
        if scenario.expected.selectedIndex == nil {
            XCTAssertTrue(results.allSatisfy { $0 == .excluded }, "[\(scenario.id)] expected every candidate excluded", file: file, line: line)
        }
    }

    // MARK: Solver parity

    func testSolverSelectionMatchesEveryCorpusScenario() throws {
        for scenario in try loadCorpus().scenarios { try replayThroughSolver(scenario) }
    }

    private func replayThroughSolver(_ scenario: ParityScenario, file: StaticString = #filePath, line: UInt = #line) throws {
        let palette = try scenario.palette.map(domainColor(from:))
        let weights = channelWeights(from: scenario.weights)
        let targetChannels = conditionValues(scenario.target.channels)

        // The solver consumes grids (a grid never "lacks" a channel), so a
        // target missing a positive-weight channel cannot be replayed through
        // it; the scorer replay pins that policy case instead.
        guard weights.activeConditions.allSatisfy({ targetChannels[$0] != nil }) else { return }

        let grids = sourceGrids(for: weights, targetChannels: targetChannels)
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, "[\(scenario.id)] solver selection", file: file, line: line)
        if let selectedIndex = scenario.expected.selectedIndex, let expectedError = scenario.expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, "[\(scenario.id)] solver error", file: file, line: line)
            XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor, "[\(scenario.id)] solver selected hex", file: file, line: line)
        } else {
            XCTAssertEqual(result.unmatchedCellCount, 1, "[\(scenario.id)] expected an unmatched cell", file: file, line: line)
        }
        let excluded = scenario.expected.scores.filter { $0.score == .excluded }.count
        XCTAssertEqual(result.excludedCandidateCount, excluded, "[\(scenario.id)] excluded candidate count", file: file, line: line)
    }

    private func sourceGrids(
        for weights: ChannelWeights,
        targetChannels: [LightingCondition: Double]
    ) -> [LightingCondition: BrightnessGrid] {
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for condition in weights.activeConditions {
            grids[condition] = BrightnessGrid(width: 1, height: 1, fill: targetChannels[condition] ?? 0)
        }
        return grids
    }

    // MARK: Documented parity findings

    /// The corpus carries an unknown light source in its weights map; the
    /// client must ignore it and land on the same selection as the canonical
    /// `distinct-errors` scenario.
    func testUnknownWeightKeysAreIgnored() throws {
        let corpus = try loadCorpus()
        let unknown = try XCTUnwrap(corpus.scenarios.first { $0.id == "unknown-weight-ignored" })
        let baseline = try XCTUnwrap(corpus.scenarios.first { $0.id == "distinct-errors" })

        XCTAssertEqual(Set(unknown.weights.keys).subtracting(baseline.weights.keys), ["ultraviolet"])
        XCTAssertEqual(unknown.expected.selectedIndex, baseline.expected.selectedIndex)
        XCTAssertEqual(unknown.expected.error, baseline.expected.error)
    }
}
