import Foundation
import XCTest
@testable import ColorComposerCore

/// Solver parity against the golden-vector corpus published by the
/// `color_matching` server (viamin/color_matching#111, landed as #112).
///
/// The corpus is vendored verbatim at
/// `Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json` (upstream:
/// `priv/parity/v1/corpus.json`, regenerated with `mix parity.generate`).
/// Every scenario records the palette response vectors, the target vector,
/// the channel weights, the per-candidate score table (`"excluded"` marks a
/// missing measurement on a positive-weight channel), the expected selection,
/// the expected error, and explicit tie-break evidence. This suite replays
/// each scenario through `WeightedSquaredErrorScorer` and asserts exact
/// agreement — any mismatch means the client has diverged from the server on
/// tie-breaking, missing-measurement exclusion, or channel weighting.
///
/// All corpus values are dyadic rationals (multiples of 1/256), so both the
/// Elixir and Swift IEEE-754 doubles compute them bit-exactly; scores are
/// compared with exact equality, not a tolerance. When the corpus
/// `algorithm_version` changes, every expectation has moved and this suite
/// must be updated in lockstep with the newly generated fixture.
///
/// The fixture is located relative to `#filePath` rather than a bundle
/// resource so it loads under plain `swift test` (and `bin/lint`) without a
/// resource declaration in `Package.swift`. See `docs/parity-corpus.md` for
/// how to refresh the corpus.
final class ParityCorpusTests: XCTestCase {
    private static let supportedAlgorithmVersion = 1

    private static let corpusURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/parity/v1/corpus.json")

    // MARK: - Corpus wire model (upstream `priv/parity/v1/corpus.json`)

    private struct Corpus: Decodable {
        let algorithmVersion: Int
        let scorer: String
        let selection: String
        let missingPolicy: String
        let lightSources: [String]
        let scenarios: [Scenario]
    }

    private struct Scenario: Decodable {
        let id: String
        let description: String
        let weights: [String: Double]
        let target: Entry
        let palette: [Entry]
        let expected: Expected
    }

    private struct Entry: Decodable {
        let index: Int?
        let hexColor: String
        let channels: [String: Double]
    }

    private struct Expected: Decodable {
        let scores: [ScoreEntry]
        let selectedIndex: Int?
        let selectedHexColor: String?
        let error: Double?
        let tieBroke: Bool?
        let tiedIndices: [Int]
    }

    private struct ScoreEntry: Decodable {
        let index: Int
        let score: ScoreValue
    }

    /// A recorded score: a finite number, or `"excluded"` when the candidate
    /// was missing a measurement on a positive-weight channel.
    private enum ScoreValue: Decodable, Equatable {
        case score(Double)
        case excluded

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let excluded = try? container.decode(String.self), excluded == "excluded" {
                self = .excluded
            } else {
                self = .score(try container.decode(Double.self))
            }
        }
    }

    // MARK: - Corpus-level stamps

    func testCorpusIsStampedWithSupportedAlgorithmVersion() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, Self.supportedAlgorithmVersion)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
    }

    /// Guards that refreshed corpora keep covering the parity classes this
    /// suite exists to enforce (mirrors the upstream corpus test's coverage
    /// check), so a regeneration cannot silently drop the hard cases.
    func testCorpusKeepsTieExclusionAndNoSelectionCoverage() throws {
        let corpus = try loadCorpus()
        XCTAssertGreaterThanOrEqual(
            corpus.scenarios.filter { $0.expected.tieBroke == true }.count, 1,
            "corpus must contain intentionally tied scenarios"
        )
        XCTAssertGreaterThanOrEqual(
            corpus.scenarios.filter { $0.expected.selectedIndex == nil }.count, 1,
            "corpus must contain scenarios where every candidate is excluded"
        )
        XCTAssertGreaterThanOrEqual(
            corpus.scenarios.flatMap(\.expected.scores).filter { $0.score == .excluded }.count, 1,
            "corpus must contain missing-measurement exclusions"
        )
        XCTAssertGreaterThanOrEqual(
            corpus.scenarios.filter { $0.expected.error == 0 }.count, 1,
            "corpus must contain an exact-match zero-error scenario"
        )
    }

    // MARK: - Scenario replay

    func testScoreTableMatchesCorpusExactly() throws {
        let corpus = try loadCorpus()
        for scenario in corpus.scenarios {
            let replay = try replay(scenario)
            XCTAssertEqual(
                replay.scores.count, scenario.expected.scores.count,
                "\(scenario.id): score table size mismatch"
            )
            for recorded in scenario.expected.scores {
                guard let actual = replay.scores[recorded.index] else {
                    XCTFail("\(scenario.id): no replayed score for candidate \(recorded.index)")
                    continue
                }
                switch (recorded.score, actual) {
                case let (.score(expected), .score(actual)):
                    XCTAssertEqual(
                        actual, expected,
                        "\(scenario.id): candidate \(recorded.index) score mismatch"
                    )
                case (.excluded, .excluded):
                    break
                default:
                    XCTFail(
                        "\(scenario.id): candidate \(recorded.index) expected \(recorded.score) but got \(actual)"
                    )
                }
            }
        }
    }

    func testSelectionMatchesCorpusIncludingTieBreaks() throws {
        let corpus = try loadCorpus()
        for scenario in corpus.scenarios {
            let replay = try replay(scenario)
            let expected = scenario.expected

            XCTAssertEqual(
                replay.selectedIndex, expected.selectedIndex,
                "\(scenario.id): selected index mismatch (earliest-index-wins)"
            )
            XCTAssertEqual(
                replay.selectedHexColor, expected.selectedHexColor,
                "\(scenario.id): selected hex color mismatch"
            )

            if let expectedError = expected.error {
                guard let actualError = replay.selectedError else {
                    return XCTFail("\(scenario.id): expected error \(expectedError) but nothing was selected")
                }
                XCTAssertEqual(actualError, expectedError, "\(scenario.id): selected error mismatch")
            } else {
                XCTAssertNil(replay.selectedError, "\(scenario.id): expected no selection")
            }

            XCTAssertEqual(
                replay.tiedIndices, expected.tiedIndices,
                "\(scenario.id): tied index set mismatch"
            )
            XCTAssertEqual(
                replay.tieBroke, expected.tieBroke,
                "\(scenario.id): tie_broke evidence mismatch"
            )
        }
    }

    /// The corpus deliberately weights unknown light sources (e.g.
    /// `ultraviolet`) that no canonical vector can measure; those keys must
    /// be ignored, and the scenario's score table must match its canonical
    /// twin scenario verbatim.
    func testUnknownWeightKeysAreIgnored() throws {
        let corpus = try loadCorpus()
        let unknown = try XCTUnwrap(corpus.scenarios.first { $0.id == "unknown-weight-ignored" })
        let twin = try XCTUnwrap(corpus.scenarios.first { $0.id == "distinct-errors" })

        let unknownKeys = Set(unknown.weights.keys)
            .subtracting(LightingCondition.all.map(\.rawValue))
        XCTAssertEqual(unknownKeys, ["ultraviolet"])
        XCTAssertEqual(unknown.expected.scores.map(\.score), twin.expected.scores.map(\.score))
        XCTAssertEqual(unknown.expected.selectedIndex, twin.expected.selectedIndex)
        XCTAssertEqual(unknown.expected.error, twin.expected.error)
    }

    // MARK: - Replay engine

    private struct Replay {
        var scores: [Int: ScoreValue]
        var selectedIndex: Int?
        var selectedHexColor: String?
        var selectedError: Double?
        var tiedIndices: [Int]
        var tieBroke: Bool?
    }

    /// Replays one scenario exactly the way the app and the server agree on:
    /// score every palette color against the target with the scenario's
    /// weights, then select with strict less-than so the earliest tied index
    /// wins (`ColorMatching.IlluminantMatching.best_match/3` semantics).
    private func replay(_ scenario: Scenario) throws -> Replay {
        let scorer = WeightedSquaredErrorScorer()
        let weights = try makeWeights(scenario.weights)
        let target = try makeTarget(scenario.target)
        let palette = try scenario.palette.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
            .map(makeColor)

        var scores: [Int: ScoreValue] = [:]
        var bestIndex: Int?
        var bestScore = Double.infinity
        for (index, color) in palette.enumerated() {
            switch scorer.score(candidate: color, target: target, weights: weights) {
            case .excluded:
                scores[index] = .excluded
            case .score(let value):
                scores[index] = .score(value)
                if value < bestScore {
                    bestScore = value
                    bestIndex = index
                }
            }
        }

        let tied: [Int]
        let tieBroke: Bool?
        if bestIndex != nil {
            tied = palette.indices.filter { scores[$0] == .score(bestScore) }
            tieBroke = tied.count > 1
        } else {
            tied = []
            tieBroke = nil
        }

        return Replay(
            scores: scores,
            selectedIndex: bestIndex,
            selectedHexColor: bestIndex.map { palette[$0].hex },
            selectedError: bestIndex == nil ? nil : bestScore,
            tiedIndices: tied,
            tieBroke: tieBroke
        )
    }

    private func makeWeights(_ raw: [String: Double]) throws -> ChannelWeights {
        func weight(_ condition: LightingCondition) -> Double {
            raw[condition.rawValue] ?? 0
        }
        return ChannelWeights(
            white: weight(.white),
            red: weight(.red),
            green: weight(.green),
            blue: weight(.blue),
            lps: weight(.lps)
        )
    }

    private func makeTarget(_ entry: Entry) throws -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in entry.channels {
            guard let condition = LightingCondition(rawValue: key) else { continue }
            brightness[condition] = value
        }
        return TargetResponseVector(brightness)
    }

    private func makeColor(_ entry: Entry) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: entry.hexColor), "corpus hex \(entry.hexColor) is not parseable")
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

    private func loadCorpus() throws -> Corpus {
        let data = try Data(contentsOf: Self.corpusURL)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Corpus.self, from: data)
        } catch {
            XCTFail("parity corpus at \(Self.corpusURL.path) failed to decode: \(error)")
            throw error
        }
    }
}
