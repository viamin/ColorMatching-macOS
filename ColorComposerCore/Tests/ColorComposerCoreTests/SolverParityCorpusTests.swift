import Foundation
import XCTest
@testable import ColorComposerCore

/// Solver parity against the golden-vector corpus published by the
/// `color_matching` server (viamin/color_matching#111).
///
/// The corpus is committed at
/// `Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json` — a
/// byte-identical copy of the server's `priv/parity/v1/corpus.json`. See
/// `docs/parity-corpus.md` for where it lives and how to refresh it.
///
/// Each scenario is replayed through `WeightedSquaredErrorScorer` exactly the
/// way the upstream README prescribes: score every palette color against the
/// scenario's target using the scenario's weights, then assert exact
/// agreement with the recorded per-candidate score table (`"excluded"` marks
/// missing-measurement exclusions), the expected selection and error, and the
/// explicit tie-break evidence. Any mismatch means this client has diverged
/// from the server on tie-breaking, missing-measurement exclusion, or channel
/// weighting.
final class SolverParityCorpusTests: XCTestCase {
    /// The corpus `algorithm_version` this client's scorer implements. When
    /// the server bumps the version every expectation has moved and the
    /// committed corpus plus this constant must be updated in step.
    private static let implementedAlgorithmVersion = 1

    private static func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parity/v1/corpus.json")
    }

    private func loadCorpus(file: StaticString = #filePath, line: UInt = #line) throws -> ParityCorpus {
        let url = Self.fixtureURL()
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(ParityCorpus.self, from: data)
        } catch {
            XCTFail("Parity corpus fixture is not decodable (\(url.path)): \(error)", file: file, line: line)
            throw error
        }
    }

    // MARK: - Corpus metadata

    /// The corpus must declare the contract this replay implements; a change
    /// upstream (new algorithm version, different scorer, different selection
    /// or missing-measurement policy) must be a loud failure here, not a
    /// silent mis-comparison.
    func testCorpusMetadataMatchesImplementedSolverContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, Self.implementedAlgorithmVersion,
                       "server bumped the parity algorithm_version — refresh the committed corpus and this constant in step")
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"],
                       "corpus light sources must match LightingCondition.all canonical order")
        XCTAssertFalse(corpus.scenarios.isEmpty, "parity corpus must contain scenarios")
    }

    /// The corpus must keep exercising the hard cases: exact ties, candidate
    /// exclusions, and no-selection scenarios. A refreshed corpus that drops
    /// them would make the replay pass vacuously.
    func testCorpusCoversTiesExclusionsAndNoSelection() throws {
        let corpus = try loadCorpus()

        let tieScenarios = corpus.scenarios.filter { $0.expected.tieBroke == true }
        let exclusionScenarios = corpus.scenarios.filter {
            $0.expected.scores.contains { $0.score == .excluded }
        }
        let noSelectionScenarios = corpus.scenarios.filter { $0.expected.selectedIndex == nil }
        let zeroErrorScenarios = corpus.scenarios.filter { $0.expected.error == 0 }

        XCTAssertFalse(tieScenarios.isEmpty, "corpus must contain tie-break scenarios")
        XCTAssertFalse(exclusionScenarios.isEmpty, "corpus must contain missing-measurement exclusion scenarios")
        XCTAssertFalse(noSelectionScenarios.isEmpty, "corpus must contain all-excluded / no-selection scenarios")
        XCTAssertFalse(zeroErrorScenarios.isEmpty, "corpus must contain an exact-match zero-error scenario")
    }

    // MARK: - Replay

    /// Every scenario: exact agreement with the score table, the selection,
    /// the error, and the tie evidence.
    func testScorerMatchesEveryCorpusScenarioExactly() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            replay(scenario)
        }
    }

    /// The scenarios the issue calls out by name — ties (earliest index wins)
    /// and exclusions — asserted individually so a failure names the case.
    func testTieScenariosSelectEarliestTiedIndex() throws {
        let corpus = try loadCorpus()

        let tieScenarios = corpus.scenarios.filter { $0.expected.tieBroke == true }
        XCTAssertGreaterThanOrEqual(tieScenarios.count, 1, "corpus tie coverage missing")

        for scenario in tieScenarios {
            guard let selectedIndex = scenario.expected.selectedIndex,
                  let tieBroke = scenario.expected.tieBroke else {
                XCTFail("scenario \(scenario.id): tie scenario must record a selection and tie_broke")
                continue
            }
            XCTAssertTrue(tieBroke)
            XCTAssertEqual(selectedIndex, scenario.expected.tiedIndices.first,
                           "scenario \(scenario.id): earliest tied index must win")
            XCTAssertGreaterThanOrEqual(scenario.expected.tiedIndices.count, 2,
                                        "scenario \(scenario.id): tie_broke requires at least two tied indices")
        }
    }

    func testExcludedCandidatesNeverSelected() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            let excludedIndices = scenario.expected.scores
                .filter { $0.score == .excluded }
                .map(\.index)
            if let selected = scenario.expected.selectedIndex {
                XCTAssertFalse(excludedIndices.contains(selected),
                               "scenario \(scenario.id): excluded candidate must never be selected")
            }
        }
    }

    // MARK: - Replay internals

    /// Replays one scenario through `WeightedSquaredErrorScorer` and asserts
    /// exact agreement with every recorded expectation.
    private func replay(_ scenario: ParityScenario, file: StaticString = #filePath, line: UInt = #line) {
        let context = "scenario \"\(scenario.id)\""
        let weights = Self.channelWeights(from: scenario.weights)
        let target = Self.targetVector(from: scenario.target)

        var palette: [PaletteColor] = []
        palette.reserveCapacity(scenario.palette.count)
        for candidate in scenario.palette {
            guard let color = Self.paletteColor(from: candidate) else {
                XCTFail("\(context): unparseable hex_color \"\(candidate.hexColor)\"", file: file, line: line)
                return
            }
            palette.append(color)
        }

        let scorer = WeightedSquaredErrorScorer()
        let results = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        assertScoreTableAgreement(scenario: scenario, results: results, context: context, file: file, line: line)
        assertSelectionAgreement(scenario: scenario, results: results, context: context, file: file, line: line)
    }

    /// Every recorded score entry must equal the replayed result exactly
    /// (`"excluded"` ↔ `.excluded`; numbers bit-for-bit — corpus values are
    /// dyadic so both implementations must sum to the identical Double), and
    /// the table must cover the whole palette.
    private func assertScoreTableAgreement(
        scenario: ParityScenario,
        results: [ScorerResult],
        context: String,
        file: StaticString,
        line: UInt
    ) {
        let table = scenario.expected.scores
        XCTAssertEqual(
            Set(table.map(\.index)), Set(0..<results.count),
            "\(context): score table must cover every palette index exactly", file: file, line: line
        )

        for entry in table {
            guard results.indices.contains(entry.index) else { continue }
            let actual = results[entry.index]
            switch entry.score {
            case .excluded:
                XCTAssertEqual(actual, .excluded,
                               "\(context): candidate \(entry.index) — expected \"excluded\", got \(actual)",
                               file: file, line: line)
            case .value(let expected):
                XCTAssertEqual(actual, .score(expected),
                               "\(context): candidate \(entry.index) — expected score \(expected), got \(actual)",
                               file: file, line: line)
            }
        }
    }

    /// Earliest-index-wins argmin over the replayed scores must reproduce the
    /// recorded selection, selected hex, error, tied indices, and tie_broke.
    private func assertSelectionAgreement(
        scenario: ParityScenario,
        results: [ScorerResult],
        context: String,
        file: StaticString,
        line: UInt
    ) {
        var selectedIndex: Int?
        var bestScore = Double.infinity
        for (index, result) in results.enumerated() {
            guard case .score(let value) = result, value < bestScore else { continue }
            bestScore = value
            selectedIndex = index
        }

        XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex,
                       "\(context): selection mismatch", file: file, line: line)

        guard let selected = selectedIndex else {
            XCTAssertTrue(scenario.expected.tiedIndices.isEmpty,
                          "\(context): no selection — tied_indices must be empty", file: file, line: line)
            XCTAssertNil(scenario.expected.tieBroke,
                         "\(context): no selection — tie_broke must be null", file: file, line: line)
            XCTAssertNil(scenario.expected.error,
                         "\(context): no selection — error must be null", file: file, line: line)
            return
        }

        let expected = scenario.expected
        XCTAssertEqual(bestScore, expected.error,
                       "\(context): minimum error mismatch", file: file, line: line)
        XCTAssertEqual(paletteHex(scenario: scenario, index: selected), expected.selectedHexColor,
                       "\(context): selected hex mismatch", file: file, line: line)

        let tiedIndices = results.indices.filter {
            if case .score(let value) = results[$0] { return value == bestScore }
            return false
        }
        XCTAssertEqual(tiedIndices, expected.tiedIndices,
                       "\(context): tied_indices mismatch", file: file, line: line)
        XCTAssertEqual(expected.tieBroke, tiedIndices.count > 1,
                       "\(context): tie_broke mismatch", file: file, line: line)
    }

    private func paletteHex(scenario: ParityScenario, index: Int) -> String? {
        scenario.palette.first { $0.index == index }?.hexColor
    }

    // MARK: - Corpus → domain conversion

    /// Unknown weight keys (e.g. `ultraviolet`) are dropped: only canonical
    /// conditions have a slot in `ChannelWeights`, matching the corpus's
    /// `unknown-weight-ignored` scenario.
    private static func channelWeights(from raw: [String: Double]) -> ChannelWeights {
        func weight(_ condition: LightingCondition) -> Double { raw[condition.rawValue] ?? 0 }
        return ChannelWeights(
            white: weight(.white),
            red: weight(.red),
            green: weight(.green),
            blue: weight(.blue),
            lps: weight(.lps)
        )
    }

    /// Palette entries carry responses only for the channels present in
    /// `channels` — a missing key is an unmeasured condition, never zero.
    private static func paletteColor(from candidate: ParityCandidate) -> PaletteColor? {
        guard let rgb = RGBColor(hex: candidate.hexColor) else { return nil }
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, value) in candidate.channels {
            guard let condition = LightingCondition(rawValue: key) else { continue }
            responses[condition] = IlluminationResponse(brightness: value)
        }
        return PaletteColor(id: candidate.index, hex: candidate.hexColor, rgb: rgb, responses: responses)
    }

    private static func targetVector(from target: ParityTarget) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in target.channels {
            if let condition = LightingCondition(rawValue: key) { brightness[condition] = value }
        }
        return TargetResponseVector(brightness)
    }
}

// MARK: - Corpus wire types

/// Wire shape of `priv/parity/v1/corpus.json` from viamin/color_matching#111.
private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case lightSources = "light_sources"
        case missingPolicy = "missing_policy"
        case scorer
        case selection
        case scenarios
    }
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityCandidate]
    let target: ParityTarget
    let weights: [String: Double]
    let expected: ParityExpectation
}

private struct ParityCandidate: Decodable {
    let index: Int
    let hexColor: String
    let channels: [String: Double]

    enum CodingKeys: String, CodingKey {
        case index
        case hexColor = "hex_color"
        case channels
    }
}

private struct ParityTarget: Decodable {
    let channels: [String: Double]
}

private struct ParityExpectation: Decodable {
    struct ScoreEntry: Decodable {
        let index: Int
        let score: ParityScore
    }

    let scores: [ScoreEntry]
    let selectedIndex: Int?
    let selectedHexColor: String?
    let error: Double?
    let tieBroke: Bool?
    let tiedIndices: [Int]

    enum CodingKeys: String, CodingKey {
        case scores
        case selectedIndex = "selected_index"
        case selectedHexColor = "selected_hex_color"
        case error
        case tieBroke = "tie_broke"
        case tiedIndices = "tied_indices"
    }
}

/// A recorded per-candidate score: a finite number, or the string
/// `"excluded"` for missing-measurement exclusions.
private enum ParityScore: Decodable, Equatable {
    case value(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let marker = try? container.decode(String.self), marker == "excluded" {
            self = .excluded
        } else {
            self = .value(try container.decode(Double.self))
        }
    }
}
