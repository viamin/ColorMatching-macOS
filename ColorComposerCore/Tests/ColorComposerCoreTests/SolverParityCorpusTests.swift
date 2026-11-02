import XCTest
@testable import ColorComposerCore

/// Replays the solver-parity corpus published by the `color_matching` server
/// (viamin/color_matching#111) through `WeightedSquaredErrorScorer` and
/// asserts exact agreement with the recorded per-candidate score table,
/// selection, error, and tie-break evidence — including tie cases.
///
/// Any mismatch means this client has diverged from the Elixir
/// `ColorMatching.WeightedSquaredError` solver on tie-breaking,
/// missing-measurement exclusion, or channel weighting.
///
/// The fixture is a byte-identical copy of the server's
/// `priv/parity/v1/corpus.json`; see `docs/solver-parity-corpus.md` for how to
/// refresh it.
final class SolverParityCorpusTests: XCTestCase {
    private var corpus: ParityCorpus!

    override func setUpWithError() throws {
        try super.setUpWithError()
        corpus = try Self.loadCorpus()
    }

    // MARK: - Corpus contract

    /// The corpus is stamped with the algorithm it pins. When the stamp
    /// changes upstream, every expectation has moved and this client must be
    /// updated in lockstep.
    func testCorpusStampMatchesImplementedContract() {
        XCTAssertEqual(corpus.algorithmVersion, 1, "algorithm_version changed: update scorer and corpus together (docs/solver-parity-corpus.md)")
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.allCases.map(\.rawValue))
    }

    /// Guards that the corpus keeps exercising the behaviors it exists for:
    /// broken ties (including a three-way tie), exclusions, and a
    /// no-survivors scenario.
    func testCorpusContainsTieAndExclusionScenarios() {
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true }, "corpus lost its tie scenarios")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tiedIndices.count >= 3 }, "corpus lost its multi-way tie scenario")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.scores.contains { $0.score == .excluded } }, "corpus lost its exclusion scenarios")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil }, "corpus lost its all-excluded scenario")
    }

    // MARK: - Parity

    func testScoreTableMatchesCorpusExactly() throws {
        for scenario in corpus.scenarios {
            let replayed = try replayScores(for: scenario)
            XCTAssertEqual(scenario.expected.scores.count, scenario.palette.count, "scenario \(scenario.id): score table and palette disagree on size")

            for entry in scenario.expected.scores {
                XCTAssertEqual(
                    replayed[entry.index],
                    entry.score,
                    "scenario \(scenario.id): score for palette index \(entry.index) diverged from the corpus"
                )
            }
        }
    }

    /// Selection, selected hex, and total error must match exactly. Ties are
    /// resolved earliest-index-wins, mirroring `ColorMatching.IlluminantMatching`.
    func testSelectionMatchesCorpusExactly() throws {
        for scenario in corpus.scenarios {
            let replayed = try replayScores(for: scenario)
            let outcome = Self.selection(from: replayed, palette: scenario.palette)
            let expected = scenario.expected

            XCTAssertEqual(outcome.selectedIndex, expected.selectedIndex, "scenario \(scenario.id): selected index")
            XCTAssertEqual(outcome.selectedHexColor, expected.selectedHexColor, "scenario \(scenario.id): selected hex color")
            XCTAssertEqual(outcome.error, expected.error, "scenario \(scenario.id): selected candidate error")
            XCTAssertEqual(outcome.tieBroke, expected.tieBroke, "scenario \(scenario.id): tie_broke evidence")
            XCTAssertEqual(outcome.tiedIndices, expected.tiedIndices, "scenario \(scenario.id): tied_indices evidence")
        }
    }

    /// Every index the corpus marks "excluded" must be excluded here, and no
    /// index the corpus scores must be excluded here — the missing-measurement
    /// policy is part of parity.
    func testExclusionsMatchCorpus() throws {
        for scenario in corpus.scenarios {
            let replayed = try replayScores(for: scenario)

            for entry in scenario.expected.scores {
                guard case .score = entry.score else {
                    XCTAssertEqual(replayed[entry.index], .excluded, "scenario \(scenario.id): index \(entry.index) must be excluded")
                    continue
                }
                guard let replayedScore = replayed[entry.index], replayedScore != .excluded else {
                    XCTFail("scenario \(scenario.id): index \(entry.index) is excluded here but scored \(entry.score) in the corpus")
                    continue
                }
                XCTAssertEqual(replayedScore, entry.score, "scenario \(scenario.id): excluded/scored disagreement at index \(entry.index)")
            }
        }
    }

    // MARK: - Named corpus behaviors

    /// Weight keys the client does not know (like the corpus's "ultraviolet")
    /// must be ignored, not rejected and not treated as a required channel.
    func testUnknownWeightChannelsAreIgnored() throws {
        let scenario = try self.scenario("unknown-weight-ignored")
        XCTAssertTrue(scenario.weights.keys.contains("ultraviolet"), "corpus scenario lost its unknown weight key")

        let replayed = try replayScores(for: scenario)
        for entry in scenario.expected.scores {
            XCTAssertEqual(replayed[entry.index], entry.score, "unknown weight channels must not change scoring")
        }
    }

    /// A channel with weight zero is not required: candidates and targets
    /// missing it are still scored, not excluded.
    func testZeroWeightMissingChannelDoesNotExclude() throws {
        let scenario = try self.scenario("zero-weight-channel-missing")

        let replayed = try replayScores(for: scenario)
        for entry in scenario.expected.scores {
            XCTAssertEqual(replayed[entry.index], entry.score, "zero-weight channels must not exclude")
        }
    }

    // MARK: - Replay

    private func replayScores(for scenario: ParityScenario) throws -> [Int: ParityScore] {
        let weights = Self.channelWeights(scenario.weights)
        let target = Self.targetVector(scenario.target)
        let scorer = WeightedSquaredErrorScorer()

        var results: [Int: ParityScore] = [:]
        for entry in scenario.palette.sorted(by: { $0.index < $1.index }) {
            let candidate = Self.paletteColor(entry)
            switch scorer.score(candidate: candidate, target: target, weights: weights) {
            case .score(let value): results[entry.index] = .score(value)
            case .excluded: results[entry.index] = .excluded
            }
        }
        return results
    }

    private func scenario(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> ParityScenario {
        guard let scenario = corpus.scenarios.first(where: { $0.id == id }) else {
            XCTFail("corpus scenario \(id) not found", file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        return scenario
    }

    private static func channelWeights(_ raw: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: raw[LightingCondition.white.rawValue] ?? 0,
            red: raw[LightingCondition.red.rawValue] ?? 0,
            green: raw[LightingCondition.green.rawValue] ?? 0,
            blue: raw[LightingCondition.blue.rawValue] ?? 0,
            lps: raw[LightingCondition.lps.rawValue] ?? 0
        )
    }

    private static func paletteColor(_ entry: ParityPaletteEntry) -> PaletteColor {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, brightness) in entry.channels {
            if let condition = LightingCondition(rawValue: key) {
                responses[condition] = IlluminationResponse(brightness: brightness)
            }
        }
        // The scorer reads only per-condition brightness; rgb is required by
        // PaletteColor and never influences parity.
        return PaletteColor(
            id: entry.index,
            hex: entry.hexColor,
            rgb: RGBColor(hex: entry.hexColor) ?? RGBColor(red: 0, green: 0, blue: 0),
            responses: responses
        )
    }

    private static func targetVector(_ target: ParityTarget) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in target.channels {
            if let condition = LightingCondition(rawValue: key) {
                brightness[condition] = value
            }
        }
        return TargetResponseVector(brightness)
    }

    /// Earliest-index-wins selection over a replayed score table, mirroring
    /// the corpus's `selection: "earliest-index-wins"` contract.
    private static func selection(from scores: [Int: ParityScore], palette: [ParityPaletteEntry]) -> ParitySelection {
        let ranked = scores
            .compactMap { index, score -> (index: Int, score: Double)? in
                guard case .score(let value) = score else { return nil }
                return (index, value)
            }
            .sorted { $0.index < $1.index }

        guard let best = ranked.min(by: { $0.score < $1.score }) else {
            return ParitySelection(selectedIndex: nil, selectedHexColor: nil, error: nil, tieBroke: nil, tiedIndices: [])
        }

        let tiedIndices = ranked.filter { $0.score == best.score }.map(\.index)
        let winner = tiedIndices[0]
        let hex = palette.first { $0.index == winner }?.hexColor
        return ParitySelection(
            selectedIndex: winner,
            selectedHexColor: hex,
            error: best.score,
            tieBroke: tiedIndices.count > 1,
            tiedIndices: tiedIndices
        )
    }

    // MARK: - Fixture loading

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parity/v1/corpus.json")
    }

    private static func loadCorpus() throws -> ParityCorpus {
        let url = fixtureURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(
                .fileNoSuchFile,
                userInfo: [
                    NSLocalizedDescriptionKey: "Parity corpus fixture is missing at \(url.path). Refresh it from the server: see docs/solver-parity-corpus.md."
                ]
            )
        }
        do {
            return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
        } catch {
            throw CocoaError(
                .fileReadCorruptFile,
                userInfo: [
                    NSLocalizedDescriptionKey: "Parity corpus fixture at \(url.path) is not the expected JSON: \(error). See docs/solver-parity-corpus.md to refresh it."
                ]
            )
        }
    }
}

// MARK: - Corpus JSON model

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
    let description: String
    let palette: [ParityPaletteEntry]
    let target: ParityTarget
    let weights: [String: Double]
    let expected: ParityExpectation
}

private struct ParityPaletteEntry: Decodable {
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
    let hexColor: String?
    let channels: [String: Double]

    enum CodingKeys: String, CodingKey {
        case hexColor = "hex_color"
        case channels
    }
}

private struct ParityExpectation: Decodable {
    let error: Double?
    let scores: [ParityScoreEntry]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]

    enum CodingKeys: String, CodingKey {
        case error
        case scores
        case selectedHexColor = "selected_hex_color"
        case selectedIndex = "selected_index"
        case tieBroke = "tie_broke"
        case tiedIndices = "tied_indices"
    }
}

private struct ParityScoreEntry: Decodable {
    let index: Int
    let score: ParityScore
}

/// A recorded score is either a finite number or the `"excluded"` marker for
/// candidates dropped by the missing-measurement policy.
private enum ParityScore: Decodable, Equatable {
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
                in: container,
                debugDescription: "parity score must be a number or \"excluded\""
            )
        }
    }
}

/// The outcome of replaying one scenario under this client's selection rule.
private struct ParitySelection: Equatable {
    let selectedIndex: Int?
    let selectedHexColor: String?
    let error: Double?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}
