import XCTest
import ColorComposerCore

/// Solver parity against the golden-vector corpus published by the
/// `color_matching` server (viamin/color_matching#111).
///
/// The corpus is the shared source of truth for the two coupled contracts this
/// app must honor: `WeightedSquaredErrorScorer` mirrors the server's
/// `ColorMatching.WeightedSquaredError` scoring, and the client's selection
/// mirrors the server's earliest-index-wins `IlluminantMatching.best_match/3`.
/// Replaying the committed bytes here catches silent divergence in
/// tie-breaking, missing-measurement exclusion, or channel weighting.
///
/// The fixture is vendored verbatim from the server repository
/// (`priv/parity/v1/corpus.json`) at
/// `Tests/ColorComposerCoreTests/Fixtures/parity-corpus.json`. Refresh
/// instructions live in `docs/parity-corpus.md`.
final class SolverParityCorpusTests: XCTestCase {
    // MARK: - Corpus contract

    func testCorpusMetadataMatchesClientContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(
            Set(corpus.lightSources),
            Set(LightingCondition.allCases.map(\.rawValue)),
            "corpus light sources must be exactly the canonical client conditions"
        )
        XCTAssertFalse(corpus.scenarios.isEmpty)
    }

    /// Guards a corpus refresh against silently losing the edge cases that
    /// make parity meaningful: exact ties (including multi-way), missing-data
    /// exclusions, a whole-palette exclusion with no selection, and a
    /// zero-error exact match.
    func testCorpusCoversTiesExclusionsAndNoSelectionCases() throws {
        let corpus = try loadCorpus()

        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true && $0.expected.tiedIndices.count > 2 })
        XCTAssertTrue(corpus.scenarios.contains { scenario in
            scenario.expected.scores.contains { $0.score == .excluded }
        })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.error == 0 })
    }

    // MARK: - Scoring parity

    func testPerCandidateScoresMatchTheServerExactly() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let colors = try scenario.palette.map(color(from:))
            let target = target(from: scenario.target)
            let weights = weights(from: scenario.weights)

            XCTAssertEqual(
                scenario.expected.scores.map(\.index),
                scenario.palette.map(\.index),
                "scenario \(scenario.id): expected scores must line up with palette indices"
            )

            for (position, candidate) in colors.enumerated() {
                let result = scorer.score(candidate: candidate, target: target, weights: weights)
                assertScore(
                    result,
                    matches: scenario.expected.scores[position].score,
                    scenarioID: scenario.id,
                    candidateIndex: position
                )
            }
        }
    }

    // MARK: - Selection parity

    func testSelectionMatchesEarliestIndexWinsIncludingTies() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let colors = try scenario.palette.map(color(from:))
            let target = target(from: scenario.target)
            let weights = weights(from: scenario.weights)
            let scores = colors.map { scorer.score(candidate: $0, target: target, weights: weights) }
            let selection = selectEarliestWinner(colors: colors, scores: scores)

            XCTAssertEqual(selection.selectedIndex, scenario.expected.selectedIndex, "scenario \(scenario.id): selected index")
            XCTAssertEqual(selection.selectedHexColor, scenario.expected.selectedHexColor, "scenario \(scenario.id): selected hex")
            if let expectedError = scenario.expected.error {
                let actualError = try XCTUnwrap(selection.error, "scenario \(scenario.id): expected a winner error")
                XCTAssertEqual(actualError, expectedError, accuracy: 1e-12, "scenario \(scenario.id): winner error")
            } else {
                XCTAssertNil(selection.selectedIndex, "scenario \(scenario.id): expected no selection")
            }
            XCTAssertEqual(selection.tiedIndices, scenario.expected.tiedIndices, "scenario \(scenario.id): tied indices")
            XCTAssertEqual(selection.tieBroke, scenario.expected.tieBroke, "scenario \(scenario.id): tie_broke")
        }
    }

    /// Unknown light-source keys in the weights map (the corpus carries
    /// `ultraviolet`) must be dropped, not rejected — matching the server's
    /// `filter_weights/1`.
    func testUnknownLightSourceWeightsAreIgnored() throws {
        let corpus = try loadCorpus()
        let scenario = try XCTUnwrap(
            corpus.scenarios.first { $0.id == "unknown-weight-ignored" },
            "corpus must keep the unknown-weight scenario"
        )
        let canonical = Set(LightingCondition.allCases.map(\.rawValue))

        XCTAssertFalse(
            scenario.weights.keys.allSatisfy(canonical.contains),
            "scenario must carry a non-canonical weight key to exercise ignoring"
        )
        XCTAssertEqual(
            weights(from: scenario.weights),
            weights(from: scenario.weights.filter { canonical.contains($0.key) })
        )
    }

    // MARK: - Corpus replay helpers

    private func loadCorpus(file: StaticString = #filePath, line: UInt = #line) throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parity-corpus.json")
        do {
            let data = try Data(contentsOf: fixtureURL)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(ParityCorpus.self, from: data)
        } catch {
            XCTFail("parity corpus fixture missing or undecodable at \(fixtureURL.path): \(error)", file: file, line: line)
            throw error
        }
    }

    private func color(from fixture: ParityCorpus.ResponseVectorFixture) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: fixture.hexColor), "corpus hex \(fixture.hexColor) must parse")
        return PaletteColor(
            id: fixture.index ?? 0,
            hex: fixture.hexColor,
            rgb: rgb,
            responses: fixture.channels.reduce(into: [LightingCondition: IlluminationResponse]()) { responses, entry in
                if let condition = LightingCondition(rawValue: entry.key) {
                    responses[condition] = IlluminationResponse(brightness: entry.value)
                }
            }
        )
    }

    private func target(from fixture: ParityCorpus.ResponseVectorFixture) -> TargetResponseVector {
        TargetResponseVector(fixture.channels.reduce(into: [LightingCondition: Double]()) { brightness, entry in
            if let condition = LightingCondition(rawValue: entry.key) {
                brightness[condition] = entry.value
            }
        })
    }

    private func weights(from raw: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: raw["white"] ?? 0,
            red: raw["red"] ?? 0,
            green: raw["green"] ?? 0,
            blue: raw["blue"] ?? 0,
            lps: raw["lps"] ?? 0
        )
    }

    private func assertScore(
        _ result: ScorerResult,
        matches expected: CorpusScore,
        scenarioID: String,
        candidateIndex: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (result, expected) {
        case (.score(let value), .score(let expectedValue)):
            XCTAssertEqual(value, expectedValue, "scenario \(scenarioID), candidate \(candidateIndex)", accuracy: 1e-12, file: file, line: line)
        case (.excluded, .excluded):
            break
        default:
            XCTFail("scenario \(scenarioID), candidate \(candidateIndex): \(result) diverged from corpus expectation \(expected)", file: file, line: line)
        }
    }

    /// Replicates the server's `IlluminantMatching.best_match/3`: strict
    /// less-than keeps the earliest index among tied minima, excluded
    /// candidates are unrankable, and a palette with no rankable candidate
    /// yields no selection.
    private func selectEarliestWinner(colors: [PaletteColor], scores: [ScorerResult]) -> Selection {
        var winner: (index: Int, score: Double, hex: String)?
        for (index, result) in scores.enumerated() {
            guard case .score(let value) = result, value < winner?.score ?? .infinity else { continue }
            winner = (index, value, colors[index].hex)
        }
        guard let winner else {
            return Selection(selectedIndex: nil, selectedHexColor: nil, error: nil, tiedIndices: [], tieBroke: nil)
        }
        let tied = scores.enumerated().compactMap { entry -> Int? in
            guard case .score(let value) = entry.element, value == winner.score else { return nil }
            return entry.offset
        }
        return Selection(
            selectedIndex: winner.index,
            selectedHexColor: winner.hex,
            error: winner.score,
            tiedIndices: tied,
            tieBroke: tied.count > 1
        )
    }

    private struct Selection {
        let selectedIndex: Int?
        let selectedHexColor: String?
        let error: Double?
        let tiedIndices: [Int]
        let tieBroke: Bool?
    }
}

// MARK: - Corpus wire format (viamin/color_matching priv/parity/v1/corpus.json)

private struct ParityCorpus: Decodable {
    struct ResponseVectorFixture: Decodable {
        let index: Int?
        let hexColor: String
        let channels: [String: Double]
    }

    struct ExpectedScore: Decodable {
        let index: Int
        let score: CorpusScore
    }

    struct Expected: Decodable {
        let scores: [ExpectedScore]
        let selectedIndex: Int?
        let selectedHexColor: String?
        let error: Double?
        let tieBroke: Bool?
        let tiedIndices: [Int]
    }

    struct Scenario: Decodable {
        let id: String
        let description: String
        let palette: [ResponseVectorFixture]
        let target: ResponseVectorFixture
        let weights: [String: Double]
        let expected: Expected
    }

    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
    let scenarios: [Scenario]
}

/// A per-candidate expected score: a finite number, or `"excluded"`.
private enum CorpusScore: Equatable, Decodable {
    case score(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .score(value)
        } else if let raw = try? container.decode(String.self), raw == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: #"corpus score must be a number or "excluded""#
            )
        }
    }
}
