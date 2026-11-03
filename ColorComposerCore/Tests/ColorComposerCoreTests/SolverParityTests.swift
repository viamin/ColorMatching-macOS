import Foundation
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import ColorComposerCore

/// Replays the `color_matching` server's solver parity corpus against the
/// mirrored `WeightedSquaredErrorScorer`.
///
/// The corpus (`ColorComposerCore/Tests/Fixtures/parity/v1/corpus.json`) is the
/// server's own golden-vector output: it pins the per-candidate scores, the
/// selected color, the expected error, and the tie evidence for twelve
/// scenarios that between them cover
///
/// - strictly distinct errors (the clear best wins outright),
/// - exact ties (symmetric around the target, duplicate vectors, three-way),
/// - candidates missing a weighted channel (excluded, never read as zero),
/// - a target missing a weighted channel (every candidate excluded),
/// - zero-weight channels (missing data neither excludes nor contributes),
/// - unknown light sources in the weight map (ignored),
/// - a mixed palette combining all of the above.
///
/// The server resolves ties by candidate position (earliest wins) and sums
/// per-channel contributions over the weighted channels; this app must match
/// both, or client and server silently disagree about which color to print.
final class SolverParityTests: XCTestCase {
    private let scorer = WeightedSquaredErrorScorer()
    private let solver = CompositionSolver()

    // MARK: - Corpus metadata

    /// The corpus header describes the coupled server-side semantics the
    /// expectations below were produced with. A changed header means the
    /// server's algorithm moved and every expectation in the corpus changed
    /// with it — the parity test must fail loudly rather than quietly accept a
    /// different algorithm.
    func testCorpusMetadataMatchesTheServerContract() throws {
        let (corpus, _) = try ParityCorpusFixture.load()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
    }

    /// The scenario set is part of the contract: a scenario disappearing or
    /// being renamed means the corpus was replaced, not refreshed.
    func testCorpusCoversTheExpectedScenarios() throws {
        let (corpus, _) = try ParityCorpusFixture.load()

        XCTAssertEqual(corpus.scenarios.map(\.id), [
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
            "mixed-large-palette"
        ])
    }

    #if canImport(CryptoKit)
    /// The committed fixture is a verbatim copy of the upstream artifact; a
    /// hand-edited corpus would make the parity test meaningless.
    func testCommittedCorpusIsTheUpstreamArtifact() throws {
        let url = try ParityCorpusFixture.url()
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        let hex = digest.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(hex, ParityCorpusFixture.expectedSHA256)
    }
    #endif

    // MARK: - Scores

    /// Every candidate's score matches the server's, exactly.
    ///
    /// The corpus values are exact binary fractions and every weight is a
    /// dyadic rational, so the sums are exactly representable and the
    /// comparison is a bit-for-bit equality check — not a tolerance that
    /// could hide a scoring change.
    func testScorerScoresMatchTheCorpusExactly() throws {
        let (corpus, _) = try ParityCorpusFixture.load()

        for scenario in corpus.scenarios {
            let weights = channelWeights(scenario.weights)
            let target = targetVector(scenario.target)
            let palette = scenario.palette.enumerated().map { paletteColor($1, fallbackIndex: $0) }

            for expected in scenario.expected.scores {
                let candidate = palette[expected.index]
                let result = scorer.score(candidate: candidate, target: target, weights: weights)

                switch (result, expected.score) {
                case (.excluded, .excluded):
                    continue
                case (.score(let value), .value(let expectedValue)):
                    XCTAssertEqual(
                        value,
                        expectedValue,
                        "scenario \(scenario.id), candidate \(expected.index)"
                    )
                case (.excluded, .value):
                    XCTFail(
                        "scenario \(scenario.id), candidate \(expected.index): "
                            + "the corpus expects a score but the candidate was excluded"
                    )
                case (.score(let value), .excluded):
                    XCTFail(
                        "scenario \(scenario.id), candidate \(expected.index): "
                            + "the corpus expects an exclusion but the candidate scored \(value)"
                    )
                }
            }
        }
    }

    // MARK: - Selection

    /// The selected color, its error, and the tie evidence match the server's.
    ///
    /// Ties resolve to the earliest candidate, exactly like the server's
    /// `IlluminantMatching.best_match/4`.
    func testSelectionMatchesTheCorpusIncludingTieCases() throws {
        let (corpus, _) = try ParityCorpusFixture.load()

        for scenario in corpus.scenarios {
            let candidates = scoredCandidates(scenario)
            let selection = earliestWinSelection(candidates)

            switch (selection, scenario.expected) {
            case (nil, let expected):
                XCTAssertNil(expected.selectedIndex, "scenario \(scenario.id)")
                XCTAssertNil(expected.error, "scenario \(scenario.id)")
                XCTAssertNil(expected.tieBroke, "scenario \(scenario.id)")
                XCTAssertTrue(expected.tiedIndices.isEmpty, "scenario \(scenario.id)")

            case (let selection?, let expected):
                guard let expectedIndex = expected.selectedIndex else {
                    return XCTFail("scenario \(scenario.id): the corpus expects a selected color")
                }
                XCTAssertEqual(selection.index, expectedIndex, "scenario \(scenario.id)")
                if let expectedHexColor = expected.selectedHexColor {
                    XCTAssertEqual(selection.hexColor, expectedHexColor, "scenario \(scenario.id)")
                } else {
                    XCTFail("scenario \(scenario.id): the corpus expects a selected color")
                }
                XCTAssertEqual(selection.tiedIndices, expected.tiedIndices, "scenario \(scenario.id)")
                XCTAssertEqual(
                    expected.tieBroke ?? false,
                    selection.tiedIndices.count > 1,
                    "scenario \(scenario.id): tie evidence"
                )
                if let expectedError = expected.error {
                    XCTAssertEqual(selection.error, expectedError, "scenario \(scenario.id)")
                } else {
                    XCTFail("scenario \(scenario.id): the corpus expects an error for the selected color")
                }
            }
        }
    }

    /// The tie-breaking policy itself: whenever the corpus records a tie, the
    /// selected color is the earliest of the tied candidates.
    func testTieCasesSelectTheEarliestTiedCandidate() throws {
        let (corpus, _) = try ParityCorpusFixture.load()
        let tieScenarios = corpus.scenarios.filter { $0.expected.tieBroke == true }

        XCTAssertFalse(tieScenarios.isEmpty, "the corpus must keep its tie scenarios")

        for scenario in tieScenarios {
            let candidates = scoredCandidates(scenario)
            guard let selection = earliestWinSelection(candidates) else {
                return XCTFail("scenario \(scenario.id): a tied corpus scenario must select a color")
            }

            XCTAssertGreaterThan(selection.tiedIndices.count, 1, "scenario \(scenario.id)")
            guard let earliestTied = selection.tiedIndices.min() else {
                return XCTFail("scenario \(scenario.id): a tie must list the tied candidates")
            }
            XCTAssertEqual(
                selection.index,
                earliestTied,
                "scenario \(scenario.id): the earliest tied candidate must win"
            )
            if let expectedIndex = scenario.expected.selectedIndex {
                XCTAssertEqual(selection.index, expectedIndex, "scenario \(scenario.id)")
            }
        }
    }

    /// Candidates missing a measurement for a weighted channel are excluded
    /// rather than scored as zero brightness.
    func testExcludedCandidatesMatchTheCorpus() throws {
        let (corpus, _) = try ParityCorpusFixture.load()
        let exclusionScenarios = corpus.scenarios.filter {
            $0.expected.scores.contains { $0.score == .excluded }
        }

        XCTAssertFalse(exclusionScenarios.isEmpty, "the corpus must keep its exclusion scenarios")

        for scenario in exclusionScenarios {
            let candidates = scoredCandidates(scenario)
            for candidate in candidates {
                let expectedScore = scenario.expected.scores.first { $0.index == candidate.index }?.score
                let expectedIsExcluded: Bool
                if let expectedScore {
                    expectedIsExcluded = expectedScore == .excluded
                } else {
                    expectedIsExcluded = false
                }
                XCTAssertEqual(
                    candidate.score == nil,
                    expectedIsExcluded,
                    "scenario \(scenario.id), candidate \(candidate.index)"
                )
            }
        }
    }

    // MARK: - Solver

    /// The solver that ships in the app selects the same color as the server.
    ///
    /// The scorer test above pins the scores; this one pins the *selection*
    /// path (the optimized nearest-neighbor fast path the app actually runs),
    /// including its earliest-wins tie-breaking.
    func testSolverSelectsTheSameColorAsTheCorpus() throws {
        let (corpus, _) = try ParityCorpusFixture.load()

        for scenario in corpus.scenarios {
            let weights = channelWeights(scenario.weights)
            let active = weights.activeEntries

            // The solver always builds a complete target from the source
            // grids, so a scenario whose *target* is missing a weighted
            // channel (the server excludes every candidate there) cannot be
            // expressed as a solve. The scorer test covers it instead.
            let targetIsMissingAWeightedChannel = active.contains { entry in
                scenario.target.channels[entry.condition.rawValue] == nil
            }
            if targetIsMissingAWeightedChannel {
                XCTAssertNil(scenario.expected.selectedIndex, "scenario \(scenario.id)")
                XCTAssertTrue(
                    scenario.expected.scores.allSatisfy { $0.score == .excluded },
                    "scenario \(scenario.id): every candidate is excluded"
                )
                continue
            }

            var sourceGrids: [LightingCondition: BrightnessGrid] = [:]
            for entry in active {
                let value = scenario.target.channels[entry.condition.rawValue] ?? 0
                sourceGrids[entry.condition] = BrightnessGrid(width: 1, height: 1, values: [value])
            }

            let palette = scenario.palette.enumerated().map { paletteColor($1, fallbackIndex: $0) }
            let result = try solver.solve(palette: palette, sourceGrids: sourceGrids, weights: weights)

            XCTAssertEqual(
                result.colorIndices[0],
                scenario.expected.selectedIndex,
                "scenario \(scenario.id): selected color"
            )
            if let expectedError = scenario.expected.error {
                XCTAssertEqual(result.errors[0], expectedError, "scenario \(scenario.id): error")
            } else {
                XCTAssertEqual(
                    result.errors[0],
                    Double.infinity,
                    "scenario \(scenario.id): an unmatched cell has an infinite error"
                )
            }
        }
    }

    // MARK: - Helpers

    /// Builds the domain objects a scenario describes and scores every
    /// candidate, mirroring the server's `score_candidates/4`.
    private func scoredCandidates(_ scenario: ParityScenario) -> [ScoredCandidate] {
        let weights = channelWeights(scenario.weights)
        let target = targetVector(scenario.target)
        let palette = scenario.palette.enumerated().map { paletteColor($1, fallbackIndex: $0) }

        return palette.enumerated().map { index, candidate in
            let score: Double?
            switch scorer.score(candidate: candidate, target: target, weights: weights) {
            case .score(let value):
                score = value
            case .excluded:
                score = nil
            }
            return ScoredCandidate(index: index, hexColor: candidate.hex, score: score)
        }
    }

    /// The server's selection policy: the lowest score wins and ties go to the
    /// earliest candidate.
    private func earliestWinSelection(
        _ candidates: [ScoredCandidate]
    ) -> (index: Int, hexColor: String, error: Double, tiedIndices: [Int])? {
        let scored = candidates.compactMap { candidate -> (index: Int, hexColor: String, score: Double)? in
            guard let score = candidate.score else { return nil }
            return (candidate.index, candidate.hexColor, score)
        }
        guard let best = scored.map(\.score).min() else { return nil }
        let tied = scored.filter { $0.score == best }.map(\.index)
        guard let winner = scored.first(where: { $0.score == best }) else { return nil }
        return (winner.index, winner.hexColor, best, tied)
    }

    /// Channel weights from the corpus' weight map. Unknown light sources
    /// (the corpus exercises one) are ignored, exactly like the server's
    /// `filter_weights/1`.
    private func channelWeights(_ weights: [String: Double]) -> ChannelWeights {
        var white = 0.0
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var lps = 0.0
        for (source, weight) in weights {
            switch source {
            case "white": white = weight
            case "red": red = weight
            case "green": green = weight
            case "blue": blue = weight
            case "lps": lps = weight
            default: continue
            }
        }
        return ChannelWeights(white: white, red: red, green: green, blue: blue, lps: lps)
    }

    /// The scenario target. Channels the corpus does not measure stay absent,
    /// so "missing" is distinguishable from "measured as zero brightness".
    private func targetVector(_ entry: ParityEntry) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (source, value) in entry.channels {
            guard let condition = LightingCondition(rawValue: source) else { continue }
            brightness[condition] = value
        }
        return TargetResponseVector(brightness)
    }

    /// A palette candidate. Only measured channels become responses; unknown
    /// light sources are ignored.
    private func paletteColor(_ entry: ParityEntry, fallbackIndex: Int) -> PaletteColor {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (source, value) in entry.channels {
            guard let condition = LightingCondition(rawValue: source) else { continue }
            responses[condition] = IlluminationResponse(brightness: value)
        }
        return PaletteColor(
            id: entry.index ?? fallbackIndex,
            hex: entry.hexColor,
            rgb: RGBColor(hex: entry.hexColor) ?? RGBColor(red: 0, green: 0, blue: 0),
            responses: responses
        )
    }
}

// MARK: - Corpus model

/// One scored candidate: `nil` score means the candidate was excluded.
private struct ScoredCandidate {
    let index: Int
    let hexColor: String
    let score: Double?
}

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
    let target: ParityEntry
    let palette: [ParityEntry]
    let expected: ParityExpectation
}

private struct ParityEntry: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpectation: Decodable {
    let scores: [ParityScoreEntry]
    let selectedIndex: Int?
    let selectedHexColor: String?
    let error: Double?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScoreEntry: Decodable {
    let index: Int
    let score: ParityScore
}

/// A corpus score is either a number or the literal `"excluded"`.
private enum ParityScore: Decodable, Equatable {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            guard text == "excluded" else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "unexpected corpus score \(text)"
                )
            }
            self = .excluded
        } else {
            self = .value(try container.decode(Double.self))
        }
    }
}

// MARK: - Corpus fixture

/// Locates and decodes the committed parity corpus.
private enum ParityCorpusFixture {
    /// SHA-256 of the upstream artifact — see `Tests/Fixtures/parity/README.md`.
    static let expectedSHA256 = "7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604"

    /// Locations of the corpus relative to the test file's directory, tried
    /// in order.
    static let relativePaths = [
        "Fixtures/parity/v1/corpus.json",
        "../Fixtures/parity/v1/corpus.json"
    ]

    enum FixtureError: Error {
        case missing
    }

    static func url() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["COLORCOMPOSER_PARITY_CORPUS"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        let sourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()

        for candidate in candidates(from: sourceDirectory) {
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }

        throw FixtureError.missing
    }

    static func load() throws -> (corpus: ParityCorpus, url: URL) {
        let url = try url()
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let corpus = try decoder.decode(ParityCorpus.self, from: data)
        return (corpus, url)
    }

    /// The corpus lives in the package's fixture directory; the upward walk
    /// keeps the lookup working in checkouts that nest the package deeper.
    private static func candidates(from sourceDirectory: URL) -> [URL] {
        var directories = [sourceDirectory]
        var directory = sourceDirectory
        for _ in 0..<5 {
            directory = directory.deletingLastPathComponent()
            directories.append(directory)
        }

        var urls: [URL] = []
        for directory in directories {
            for relativePath in relativePaths {
                urls.append(
                    directory
                        .appendingPathComponent(relativePath)
                        .standardizedFileURL
                )
            }
        }
        return urls
    }
}
