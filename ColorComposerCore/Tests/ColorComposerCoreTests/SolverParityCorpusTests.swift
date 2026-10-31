import XCTest
@testable import ColorComposerCore

/// Golden-vector solver parity with the Elixir `color_matching` service.
///
/// This suite replays the committed parity corpus — the shared source of truth
/// published by viamin/color_matching#111 — through
/// `WeightedSquaredErrorScorer` and asserts **exact** agreement with the
/// server-computed expectations: per-candidate scores, the earliest-wins
/// selection, tie evidence, and missing-measurement exclusions.
///
/// The corpus lives at `Fixtures/parity/v1/corpus.json` next to this file
/// (see `docs/parity-corpus.md` for provenance and the refresh procedure). It
/// is byte-identical to `priv/parity/v1/corpus.json` in the `color_matching`
/// repo, where `mix parity.generate` regenerates it deterministically.
///
/// Mirrors `ColorMatching.Parity.CorpusTest` on the server side: any change
/// here in tie-breaking, exclusion, or weighting (or any change there) shows
/// up as a mismatch and requires bumping the corpus `algorithm_version`.
///
/// Swift `Double` and Elixir floats are both IEEE-754 binaries, and every
/// corpus value is an exactly representable dyadic rational, so equality is
/// compared with `==` — no epsilon tolerance.
final class SolverParityCorpusTests: XCTestCase {
    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/parity/v1/corpus.json")

    private let scorer = WeightedSquaredErrorScorer()

    // MARK: - Corpus fixture

    func testCorpusFixtureIsCommittedAndDecodable() throws {
        let corpus = try Self.loadCorpus()
        XCTAssertGreaterThan(corpus.scenarios.count, 0)
    }

    func testCorpusIsStampedWithTheContractMetadata() throws {
        let corpus = try Self.loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
    }

    /// The canonical channel order is itself part of the parity contract: the
    /// scorer accumulates per-channel contributions in this order.
    func testCorpusLightSourcesMatchCanonicalChannelOrder() throws {
        let corpus = try Self.loadCorpus()

        XCTAssertEqual(corpus.lightSources, LightingCondition.allCases.map(\.rawValue))
    }

    /// A corpus that no longer exercises ties or all-excluded outcomes cannot
    /// guard parity; this pins the corpus's own coverage the way the Elixir
    /// suite does.
    func testCorpusContainsIntentionallyTiedAndNullSelectionScenarios() throws {
        let scenarios = try Self.loadCorpus().scenarios

        XCTAssertGreaterThanOrEqual(scenarios.filter { $0.expected.tieBroke == true }.count, 1)
        XCTAssertGreaterThanOrEqual(scenarios.filter { $0.expected.selectedIndex == nil }.count, 1)
        XCTAssertGreaterThanOrEqual(
            scenarios.filter { scenario in scenario.expected.scores.contains { $0.score.isExcluded } }.count,
            1
        )
    }

    // MARK: - Full replay

    /// Every scenario must agree exactly: per-candidate scores, selection,
    /// error, hex, and tie evidence.
    func testReplayOfEveryScenarioMatchesExpectedOutputsExactly() throws {
        let corpus = try Self.loadCorpus()

        for scenario in corpus.scenarios {
            replayAndAssertAgreement(scenario)
        }
    }

    func testReplayTieScenariosSelectTheEarliestTiedIndex() throws {
        let tied = try Self.loadCorpus().scenarios.filter { $0.expected.tieBroke == true }

        XCTAssertGreaterThanOrEqual(tied.count, 1, "corpus must contain tied scenarios")
        for scenario in tied {
            replayAndAssertAgreement(scenario)
            XCTAssertEqual(
                scenario.expected.tiedIndices.first,
                scenario.expected.selectedIndex,
                "\(scenario.id): the earliest tied index must be the selected index"
            )
        }
    }

    func testReplayExclusionScenariosExcludeRatherThanTreatMissingAsZero() throws {
        let excluding = try Self.loadCorpus().scenarios
            .filter { scenario in scenario.expected.scores.contains { $0.score.isExcluded } }

        XCTAssertGreaterThanOrEqual(excluding.count, 1)
        for scenario in excluding {
            replayAndAssertAgreement(scenario)
        }
    }

    func testReplayNullSelectionScenariosAdmitNoSelection() throws {
        let null = try Self.loadCorpus().scenarios.filter { $0.expected.selectedIndex == nil }

        XCTAssertGreaterThanOrEqual(null.count, 1)
        for scenario in null {
            replayAndAssertAgreement(scenario)
        }
    }

    // MARK: - Replay engine

    /// Scores every candidate, then applies the earliest-wins selection of
    /// `ColorMatching.IlluminantMatching.best_match/4`, asserting each corpus
    /// expectation in turn — the exact analogue of the Elixir replay test.
    private func replayAndAssertAgreement(_ scenario: ParityScenario) {
        let weights = Self.channelWeights(from: scenario.weights)
        let target = Self.targetVector(from: scenario.target)
        let palette = scenario.palette
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
            .map(Self.paletteColor(from:))

        assertScores(palette: palette, target: target, weights: weights, scenario: scenario)
        let best = assertSelection(palette: palette, target: target, weights: weights, scenario: scenario)
        assertTieEvidence(scored: score(palette: palette, target: target, weights: weights),
                          best: best,
                          scenario: scenario)
    }

    private func score(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> [ScorerResult] {
        palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
    }

    /// Per-candidate scores must match exactly — `"excluded"` markers and
    /// bit-identical doubles, with no tolerance.
    private func assertScores(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights,
        scenario: ParityScenario
    ) {
        let scored = score(palette: palette, target: target, weights: weights)
        let expected = scenario.expected.scores.sorted { $0.index < $1.index }

        XCTAssertEqual(scored.count, expected.count, scenario.id)
        for (candidateIndex, (result, expectation)) in zip(scored, expected).enumerated() {
            XCTAssertEqual(expectation.index, candidateIndex, "\(scenario.id): score entries must be index-ordered")
            switch (result, expectation.score) {
            case (.excluded, .excluded):
                continue
            case (.score(let value), .value(let expectedValue)):
                XCTAssertTrue(
                    value == expectedValue,
                    "\(scenario.id)[\(candidateIndex)]: score \(value) != expected \(expectedValue)"
                )
            default:
                XCTFail("\(scenario.id)[\(candidateIndex)]: expected \(expectation.score), got \(result)")
            }
        }
    }

    /// The selection (index, hex, error) must match, and scenarios with no
    /// expectation of a selection must admit none. Returns the replayed best
    /// match for tie-evidence checking.
    private func assertSelection(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights,
        scenario: ParityScenario
    ) -> (index: Int, score: Double)? {
        let best = replayBestMatch(palette: palette, target: target, weights: weights)
        let expected = scenario.expected

        guard let selectedIndex = expected.selectedIndex else {
            XCTAssertNil(best, "\(scenario.id): expected no selection, got \(String(describing: best))")
            return nil
        }

        guard let best else {
            XCTFail("\(scenario.id): expected selection at index \(selectedIndex), got none")
            return nil
        }

        XCTAssertEqual(best.index, selectedIndex, scenario.id)
        XCTAssertEqual(best.score, expected.error, "\(scenario.id): selected error must match exactly")
        XCTAssertEqual(palette[best.index].hex, expected.selectedHexColor, scenario.id)
        return best
    }

    /// Recomputes the tie set from the replayed scores and checks the corpus's
    /// own tie evidence: the tied indices, whether a tie was broken, and that
    /// the winner is the earliest member of the tied set.
    private func assertTieEvidence(
        scored: [ScorerResult],
        best: (index: Int, score: Double)?,
        scenario: ParityScenario
    ) {
        let expected = scenario.expected

        guard let best else {
            XCTAssertNil(expected.tieBroke, scenario.id)
            XCTAssertEqual(expected.tiedIndices, [], scenario.id)
            return
        }

        let tied = scored.enumerated().compactMap { index, result -> Int? in
            guard case .score(let value) = result, value == best.score else { return nil }
            return index
        }

        XCTAssertEqual(tied, expected.tiedIndices, scenario.id)
        XCTAssertEqual(expected.tieBroke, tied.count > 1, scenario.id)
        XCTAssertEqual(tied.first, expected.selectedIndex, scenario.id)
    }

    /// Earliest-wins best match over the scorer — the client-side mirror of
    /// `IlluminantMatching.best_match/4` (strict `<` keeps the first minimum).
    private func replayBestMatch(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> (index: Int, score: Double)? {
        var best: (index: Int, score: Double)?
        for (index, color) in palette.enumerated() {
            guard case .score(let value) = scorer.score(candidate: color, target: target, weights: weights) else {
                continue
            }
            if value < (best?.score ?? .infinity) {
                best = (index, value)
            }
        }
        return best
    }

    // MARK: - Corpus decoding

    private static func loadCorpus(file: StaticString = #filePath, line: UInt = #line) throws -> ParityCorpus {
        let url = fixtureURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("parity corpus fixture is missing at \(url.path); see docs/parity-corpus.md to refresh it", file: file, line: line)
            throw FixtureError.missing(url)
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(ParityCorpus.self, from: data)
        } catch {
            XCTFail("parity corpus fixture failed to decode: \(error)", file: file, line: line)
            throw error
        }
    }

    private enum FixtureError: Error {
        case missing(URL)
    }

    /// Maps encoded weights onto `ChannelWeights`. Unknown light-source keys
    /// (e.g. `ultraviolet` in the `unknown-weight-ignored` scenario) are
    /// dropped, mirroring the Elixir scorer's `filter_weights/1`.
    private static func channelWeights(from encoded: [String: Double]) -> ChannelWeights {
        var weights = ChannelWeights()
        for (key, value) in encoded {
            switch LightingCondition(rawValue: key) {
            case .white: weights.white = value
            case .red: weights.red = value
            case .green: weights.green = value
            case .blue: weights.blue = value
            case .lps: weights.lps = value
            case nil: continue
            }
        }
        return weights
    }

    /// Channels absent from the encoded vector are absent from the target —
    /// "missing", never "zero brightness".
    private static func targetVector(from entry: ParityVector) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in entry.channels {
            guard let condition = LightingCondition(rawValue: key) else { continue }
            brightness[condition] = value
        }
        return TargetResponseVector(brightness)
    }

    private static func paletteColor(from entry: ParityVector) -> PaletteColor {
        let rgb = RGBColor(hex: entry.hexColor) ?? RGBColor(red: 0, green: 0, blue: 0)
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, value) in entry.channels {
            guard let condition = LightingCondition(rawValue: key) else { continue }
            responses[condition] = IlluminationResponse(brightness: value)
        }
        return PaletteColor(
            id: entry.index ?? 0,
            hex: entry.hexColor,
            rgb: rgb,
            responses: responses
        )
    }
}

// MARK: - Corpus wire DTOs

/// Shape of the committed corpus fixture (see `docs/parity-corpus.md`).
/// Field names rely on `convertFromSnakeCase`, matching the upstream JSON
/// produced by `ColorMatching.Parity.Corpus.encode/1`.
private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let description: String
    let weights: [String: Double]
    let target: ParityVector
    let palette: [ParityVector]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
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

/// A corpus score is either the marker string `"excluded"` or an exact double.
private enum ParityScoreValue: Decodable, Equatable {
    case excluded
    case value(Double)

    var isExcluded: Bool { self == .excluded }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let marker = try? container.decode(String.self), marker == "excluded" {
            self = .excluded
        } else {
            self = .value(try container.decode(Double.self))
        }
    }
}
