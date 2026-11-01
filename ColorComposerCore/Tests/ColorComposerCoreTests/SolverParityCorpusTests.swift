import Foundation
import XCTest
@testable import ColorComposerCore

/// Solver-parity harness for the corpus published by `color_matching`
/// (viamin/color_matching#111, vendored byte-for-byte at
/// `Fixtures/parity/corpus.v1.json` — see `docs/solver-parity-corpus.md`
/// for the schema and the refresh procedure).
///
/// Each corpus scenario carries a palette, a target vector, channel weights,
/// and the expected outcome of the Elixir `ColorMatching.WeightedSquaredError`
/// solver: per-index scores (with exclusions), the selected index, the winning
/// error, the tied-index set, and the `tie_broke` flag. These tests replay
/// every scenario through `WeightedSquaredErrorScorer` and assert the Swift
/// selections match the expected outputs exactly — including tie cases
/// (`selection: earliest-index-wins`) and missing-measurement exclusions
/// (`missing_policy: excluded-when-any-positive-weight-channel-missing`).
final class SolverParityCorpusTests: XCTestCase {
    private static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/parity", isDirectory: true)

    private static let tieEpsilon = 1e-12

    /// The committed corpus. `COLOR_MATCHING_PARITY_CORPUS` overrides the
    /// path so a freshly generated candidate corpus can be tried before it is
    /// committed.
    private func corpusURL() -> URL {
        let override = ProcessInfo.processInfo.environment["COLOR_MATCHING_PARITY_CORPUS"]
        if let override, !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return Self.fixturesDirectory.appendingPathComponent("corpus.v1.json")
    }

    private func loadCorpus() throws -> ParityCorpus {
        let url = corpusURL()
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(ParityCorpus.self, from: data)
        } catch {
            XCTFail("Parity corpus at \(url.path) does not decode against the v1 schema: \(error)")
            throw error
        }
    }

    // MARK: - Metadata and coverage

    /// The corpus pins the contract it exercises; a change here means the
    /// vendored copy and the parity expectations must be consciously refreshed
    /// together (see docs/solver-parity-corpus.md).
    func testCorpusMetadataPinsTheSolverContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1, "corpus algorithm_version changed — refresh the vendored copy and re-review parity")
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
    }

    /// Parity is only meaningful if the corpus keeps exercising the risky
    /// behavior: exact ties, candidate/target exclusions, zero-weight
    /// channels, and unknown light-source keys in weights.
    func testCorpusCoversTiesExclusionsAndWeightHandling() throws {
        let corpus = try loadCorpus()
        let scenarios = corpus.scenarios

        XCTAssertGreaterThanOrEqual(scenarios.count, 8, "corpus unexpectedly small — the vendored copy may be truncated")
        XCTAssertEqual(Set(scenarios.map(\.id)).count, scenarios.count, "scenario ids must be unique")

        XCTAssertTrue(
            scenarios.contains { $0.expected.tieBroke == true },
            "corpus must contain at least one tie scenario broken by earliest-index-wins"
        )
        XCTAssertTrue(
            scenarios.contains { $0.expected.selectedIndex == nil },
            "corpus must contain a no-selection scenario (all candidates excluded)"
        )
        XCTAssertTrue(
            scenarios.contains { scenario in scenario.expected.scores.contains { $0.score == .excluded } },
            "corpus must contain an excluded-candidate scenario"
        )
        XCTAssertTrue(
            scenarios.contains { $0.weights.values.contains(0) },
            "corpus must contain a zero-weight channel scenario"
        )
        XCTAssertTrue(
            scenarios.contains { scenario in scenario.weights.keys.contains { LightingCondition(rawValue: $0) == nil } },
            "corpus must contain a scenario with an unknown light-source key in weights"
        )
    }

    // MARK: - Parity

    /// Replays every scenario through `WeightedSquaredErrorScorer` and asserts
    /// per-candidate scores, exclusions, selection (earliest-index-wins on
    /// ties), the winning error, the tied-index set, and the selected hex all
    /// match the Elixir expected output exactly.
    func testEveryScenarioMatchesElixirExpectedOutcome() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            let palette = try domainColors(for: scenario)
            let target = targetVector(for: scenario)
            let weights = channelWeights(for: scenario)
            let scorer = WeightedSquaredErrorScorer()

            let indexed = palette
                .sorted { $0.id < $1.id }
                .map { color -> (index: Int, result: ScorerResult) in
                    (color.id, scorer.score(candidate: color, target: target, weights: weights))
                }
            try assertScores(in: indexed, match: scenario)
            try assertSelection(in: indexed, palette: palette, matches: scenario)
        }
    }

    // MARK: - Harness

    private func assertScores(
        in indexed: [(index: Int, result: ScorerResult)],
        match scenario: ParityCorpus.Scenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            Set(indexed.map(\.index)),
            Set(scenario.expected.scores.map(\.index)),
            "scenario \(scenario.id): scored indices must cover the palette",
            file: file, line: line
        )

        var actualByIndex: [Int: ScorerResult] = [:]
        for entry in indexed {
            actualByIndex[entry.index] = entry.result
        }

        for expected in scenario.expected.scores {
            switch (actualByIndex[expected.index], expected.score) {
            case (.excluded?, .excluded):
                break
            case (.score(let value)?, .value(let expectedValue)):
                XCTAssertEqual(
                    value, expectedValue, accuracy: Self.tieEpsilon,
                    "scenario \(scenario.id): candidate \(expected.index) score mismatch",
                    file: file, line: line
                )
            default:
                XCTFail(
                    "scenario \(scenario.id): candidate \(expected.index) expected \(expected.score) but got \(String(describing: actualByIndex[expected.index]))",
                    file: file, line: line
                )
            }
        }
    }

    /// Mirrors `CompositionSolver.bestCandidate`: strictly-lower wins, so the
    /// earliest index keeps the selection on exact ties.
    private func assertSelection(
        in indexed: [(index: Int, result: ScorerResult)],
        palette: [PaletteColor],
        matches scenario: ParityCorpus.Scenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var selectedIndex: Int?
        var bestScore = Double.infinity
        for entry in indexed {
            guard case .score(let score) = entry.result else { continue }
            if score < bestScore {
                bestScore = score
                selectedIndex = entry.index
            }
        }

        XCTAssertEqual(
            selectedIndex, scenario.expected.selectedIndex,
            "scenario \(scenario.id): selection mismatch (earliest-index-wins)",
            file: file, line: line
        )

        guard let expectedIndex = scenario.expected.selectedIndex else {
            XCTAssertNil(scenario.expected.error, "scenario \(scenario.id): no selection must carry no error", file: file, line: line)
            XCTAssertTrue(scenario.expected.tiedIndices.isEmpty, "scenario \(scenario.id): no selection must carry no tied indices", file: file, line: line)
            XCTAssertNil(scenario.expected.tieBroke, "scenario \(scenario.id): no selection must carry no tie_broke flag", file: file, line: line)
            XCTAssertNil(scenario.expected.selectedHexColor, "scenario \(scenario.id): no selection must carry no hex", file: file, line: line)
            return
        }

        let expectedError = try XCTUnwrap(
            scenario.expected.error,
            "scenario \(scenario.id): a selection must carry the winning error",
            file: file, line: line
        )
        XCTAssertEqual(bestScore, expectedError, accuracy: Self.tieEpsilon, "scenario \(scenario.id): winning error mismatch", file: file, line: line)

        let selected = palette.first { $0.id == expectedIndex }
        XCTAssertEqual(selected?.hex, scenario.expected.selectedHexColor, "scenario \(scenario.id): selected hex_color mismatch", file: file, line: line)

        let tied = indexed.compactMap { entry -> Int? in
            guard case .score(let score) = entry.result, abs(score - bestScore) <= Self.tieEpsilon else { return nil }
            return entry.index
        }.sorted()
        XCTAssertEqual(tied, scenario.expected.tiedIndices, "scenario \(scenario.id): tied-index set mismatch", file: file, line: line)
        XCTAssertEqual(scenario.expected.tieBroke, tied.count > 1, "scenario \(scenario.id): tie_broke flag mismatch", file: file, line: line)
        XCTAssertEqual(selectedIndex, tied.first, "scenario \(scenario.id): the selection must be the earliest tied index", file: file, line: line)
    }

    private func domainColors(for scenario: ParityCorpus.Scenario) throws -> [PaletteColor] {
        try scenario.palette.map { candidate in
            guard let rgb = RGBColor(hex: candidate.hexColor) else {
                throw ParityHarnessError.unparseableHex(candidate.hexColor, scenarioID: scenario.id)
            }
            var responses: [LightingCondition: IlluminationResponse] = [:]
            for (key, brightness) in candidate.channels {
                if let condition = LightingCondition(rawValue: key) {
                    responses[condition] = IlluminationResponse(brightness: brightness)
                }
            }
            return PaletteColor(id: candidate.index, hex: candidate.hexColor, rgb: rgb, responses: responses)
        }
    }

    private func targetVector(for scenario: ParityCorpus.Scenario) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in scenario.target.channels {
            if let condition = LightingCondition(rawValue: key) {
                brightness[condition] = value
            }
        }
        return TargetResponseVector(brightness)
    }

    /// Weight keys outside the canonical light sources (e.g. `ultraviolet`)
    /// are ignored, mirroring how `PaletteColorDTO.toDomain` drops unknown
    /// response keys.
    private func channelWeights(for scenario: ParityCorpus.Scenario) -> ChannelWeights {
        var weights = ChannelWeights()
        for (key, value) in scenario.weights {
            switch LightingCondition(rawValue: key) {
            case .some(.white): weights.white = value
            case .some(.red): weights.red = value
            case .some(.green): weights.green = value
            case .some(.blue): weights.blue = value
            case .some(.lps): weights.lps = value
            case nil: break
            }
        }
        return weights
    }
}

private enum ParityHarnessError: Error, CustomStringConvertible {
    case unparseableHex(String, scenarioID: String)

    var description: String {
        switch self {
        case .unparseableHex(let hex, let scenarioID):
            return "scenario \(scenarioID): palette hex \(hex) does not parse as an RGB color"
        }
    }
}

// MARK: - Corpus wire model (v1, snake_case)

private enum CorpusScore: Equatable, Decodable {
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
                debugDescription: "expected a numeric score or the string \"excluded\""
            )
        }
    }
}

private struct ParityCorpus: Decodable {
    struct Scenario: Decodable {
        struct Candidate: Decodable {
            let index: Int
            let hexColor: String
            let channels: [String: Double]
        }

        struct Target: Decodable {
            let index: Int?
            let hexColor: String?
            let channels: [String: Double]
        }

        struct Expected: Decodable {
            struct IndexedScore: Decodable {
                let index: Int
                let score: CorpusScore
            }

            let selectedIndex: Int?
            let selectedHexColor: String?
            let error: Double?
            let tieBroke: Bool?
            let tiedIndices: [Int]
            let scores: [IndexedScore]
        }

        let id: String
        let description: String?
        let weights: [String: Double]
        let palette: [Candidate]
        let target: Target
        let expected: Expected
    }

    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
    let scenarios: [Scenario]
}
