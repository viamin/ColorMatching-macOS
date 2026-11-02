import XCTest
@testable import ColorComposerCore

/// Replays the committed golden-vector parity corpus — the shared solver
/// contract with the Elixir `color_matching` service — through
/// `WeightedSquaredErrorScorer` and asserts exact agreement.
///
/// The corpus is the parity contract published by viamin/color_matching
/// (see `docs/solver-parity-corpus.md`): every scenario is a palette, a
/// target vector, per-channel weights, and the exact scores/selection the
/// Elixir `ColorMatching.WeightedSquaredError` scorer plus
/// earliest-index-wins selection produce. Any divergence in
/// missing-measurement exclusion, tie-breaking, or channel weighting shows
/// up here as a mismatch, mirroring upstream's
/// `test/color_matching/parity/corpus_test.exs`.
///
/// All corpus values are dyadic rationals, so both implementations compute
/// bit-identical doubles and the assertions compare for equality — never
/// within an accuracy.
final class SolverParityCorpusTests: XCTestCase {
    private static let corpusURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/parity/v1/corpus.json")

    private enum CorpusError: Error {
        case fixtureMissing(String)
    }

    // MARK: - Corpus contract

    func testCorpusIsStampedWithTheCurrentAlgorithmContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
    }

    func testCorpusContainsIntentionalTieAndNoSelectionScenarios() throws {
        let scenarios = try loadCorpus().scenarios

        XCTAssertGreaterThanOrEqual(
            scenarios.filter { $0.expected.tieBroke == true }.count, 1,
            "the corpus must keep exercising exact ties"
        )
        XCTAssertGreaterThanOrEqual(
            scenarios.filter { $0.expected.selectedIndex == nil }.count, 1,
            "the corpus must keep exercising all-excluded targets with no selection"
        )
    }

    // MARK: - Scenario replay

    func testEveryScenarioScoresExactlyAsTheServerDid() throws {
        for scenario in try loadCorpus().scenarios {
            let replay = replay(scenario)
            let expected = scenario.expected.scores.sorted { $0.index < $1.index }

            XCTAssertEqual(scenario.palette.count, expected.count, scenario.id)
            for (position, pair) in zip(replay.outcomes, expected).enumerated() {
                switch (pair.element.0, pair.element.1.score) {
                case (.excluded, .excluded):
                    continue
                case (.score(let actual), .score(let expectedScore)):
                    XCTAssertEqual(
                        actual, expectedScore,
                        "\(scenario.id): candidate \(position) score"
                    )
                case let (actual, expectedScore):
                    XCTFail(
                        "\(scenario.id): candidate \(position) produced \(actual) " +
                        "but the corpus expects \(expectedScore)"
                    )
                }
            }
        }
    }

    func testEveryScenarioSelectionMatchesExactlyIncludingTies() throws {
        for scenario in try loadCorpus().scenarios {
            let replay = replay(scenario)
            let expected = scenario.expected

            XCTAssertEqual(
                replay.selectedIndex, expected.selectedIndex,
                "\(scenario.id): selected index (earliest-wins)"
            )
            XCTAssertEqual(
                replay.tiedIndices, expected.tiedIndices,
                "\(scenario.id): tied indices"
            )

            guard let selectedIndex = replay.selectedIndex,
                  let selectedError = replay.selectedError
            else {
                XCTAssertNil(expected.tieBroke, "\(scenario.id): no selection must carry no tie evidence")
                XCTAssertTrue(expected.tiedIndices.isEmpty, "\(scenario.id): no selection must have no ties")
                continue
            }

            XCTAssertEqual(
                replay.palette[selectedIndex].hexColor, expected.selectedHexColor,
                "\(scenario.id): selected hex color"
            )
            XCTAssertEqual(
                selectedError, expected.error ?? -1,
                "\(scenario.id): winning error"
            )
            XCTAssertEqual(
                expected.tieBroke, replay.tiedIndices.count > 1,
                "\(scenario.id): tie_broke flag"
            )
            XCTAssertEqual(
                replay.tiedIndices.first, expected.selectedIndex,
                "\(scenario.id): the tie set must lead with the winner"
            )
        }
    }

    // MARK: - Replay helpers

    private struct ScenarioReplay {
        let palette: [ParityCorpus.Entry]
        let outcomes: [ScorerResult]
        let selectedIndex: Int?
        let selectedError: Double?

        /// Every rankable candidate whose score equals the winner's, in
        /// ascending index order — the set the tie-break policy chose from.
        var tiedIndices: [Int] {
            guard let selectedError = selectedError else { return [] }
            return outcomes.enumerated().compactMap { item in
                guard case .score(let value) = item.element, value == selectedError else { return nil }
                return item.offset
            }
        }
    }

    private func replay(_ scenario: ParityCorpus.Scenario) -> ScenarioReplay {
        let weights = Self.makeWeights(scenario.weights)
        let target = Self.makeTarget(scenario.target)
        let palette = scenario.palette.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        let scorer = WeightedSquaredErrorScorer()

        var outcomes: [ScorerResult] = []
        outcomes.reserveCapacity(palette.count)
        for entry in palette {
            let candidate = Self.makeColor(entry)
            outcomes.append(scorer.score(candidate: candidate, target: target, weights: weights))
        }

        // Earliest-index-wins selection, matching IlluminantMatching.best_match/4.
        var selectedIndex: Int?
        var selectedError: Double?
        for item in outcomes.enumerated() {
            guard case .score(let value) = item.element else { continue }
            if let current = selectedError, value >= current { continue }
            selectedIndex = item.offset
            selectedError = value
        }

        return ScenarioReplay(
            palette: palette,
            outcomes: outcomes,
            selectedIndex: selectedIndex,
            selectedError: selectedError
        )
    }

    /// Weight keys outside the canonical light sources (e.g. `ultraviolet`)
    /// are dropped: `LightingCondition` is the single source of truth.
    private static func makeWeights(_ raw: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: raw[LightingCondition.white.rawValue] ?? 0,
            red: raw[LightingCondition.red.rawValue] ?? 0,
            green: raw[LightingCondition.green.rawValue] ?? 0,
            blue: raw[LightingCondition.blue.rawValue] ?? 0,
            lps: raw[LightingCondition.lps.rawValue] ?? 0
        )
    }

    private static func makeTarget(_ entry: ParityCorpus.Entry) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in entry.channels {
            guard let condition = LightingCondition(rawValue: key) else { continue }
            brightness[condition] = value
        }
        return TargetResponseVector(brightness)
    }

    private static func makeColor(_ entry: ParityCorpus.Entry) -> PaletteColor {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, value) in entry.channels {
            guard let condition = LightingCondition(rawValue: key) else { continue }
            responses[condition] = IlluminationResponse(brightness: value)
        }
        return PaletteColor(
            id: entry.index ?? 0,
            hex: entry.hexColor,
            rgb: RGBColor(hex: entry.hexColor) ?? RGBColor(red: 0, green: 0, blue: 0),
            responses: responses
        )
    }

    private func loadCorpus(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> ParityCorpus {
        guard let data = try? Data(contentsOf: Self.corpusURL) else {
            XCTFail(
                "parity corpus fixture is missing at \(Self.corpusURL.path); " +
                "see docs/solver-parity-corpus.md for how to (re)fetch it",
                file: file, line: line
            )
            throw CorpusError.fixtureMissing(Self.corpusURL.path)
        }
        return try JSONDecoder().decode(ParityCorpus.self, from: data)
    }
}

// MARK: - Wire decoding (snake_case, mirrors the upstream corpus schema)

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
    let scenarios: [Scenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case scorer
        case selection
        case missingPolicy = "missing_policy"
        case lightSources = "light_sources"
        case scenarios
    }

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

        enum CodingKeys: String, CodingKey {
            case index
            case hexColor = "hex_color"
            case channels
        }
    }

    struct Expected: Decodable {
        let scores: [ExpectedScore]
        let selectedIndex: Int?
        let selectedHexColor: String?
        let error: Double?
        let tieBroke: Bool?
        let tiedIndices: [Int]

        enum CodingKeys: String, CodingKey {
            case scores
            case error
            case selectedIndex = "selected_index"
            case selectedHexColor = "selected_hex_color"
            case tieBroke = "tie_broke"
            case tiedIndices = "tied_indices"
        }
    }

    struct ExpectedScore: Decodable {
        let index: Int
        let score: Score
    }

    /// The corpus encodes an excluded candidate as the string `"excluded"`
    /// and a rankable one as a bare number.
    enum Score: Decodable, CustomStringConvertible {
        case score(Double)
        case excluded

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let label = try? container.decode(String.self), label == "excluded" {
                self = .excluded
            } else {
                self = .score(try container.decode(Double.self))
            }
        }

        var description: String {
            switch self {
            case .score(let value): return ".score(\(value))"
            case .excluded: return ".excluded"
            }
        }
    }
}
