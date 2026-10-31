import XCTest
@testable import ColorComposerCore

/// Replays the committed solver parity corpus through the client solver and
/// asserts exact agreement with the Elixir `ColorMatching.WeightedSquaredError`
/// results the corpus records.
///
/// The corpus is the shared contract published by the `color_matching` server
/// (viamin/color_matching#112, committed here byte-identical from
/// `priv/parity/v1/corpus.json`): any divergence in missing-measurement
/// exclusion, tie-breaking, or channel weighting between
/// `WeightedSquaredErrorScorer` and the server shows up as a mismatch here and
/// means the server's solver semantics changed (bump `algorithm_version` and
/// refresh the fixture).
///
/// Scores are compared with exact `==`, not a tolerance: every corpus value is
/// an exact binary fraction, so both languages compute bit-identical doubles
/// and any difference is a real semantic change.
final class SolverParityCorpusTests: XCTestCase {
    private static let corpusURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent("parity-v1-corpus.json")

    // MARK: - Corpus decoding

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
        let target: Vector
        let palette: [Vector]
        let expected: Expected
    }

    private struct Vector: Decodable, Equatable {
        let index: Int?
        let hexColor: String
        let channels: [String: Double]
    }

    private struct Expected: Decodable {
        let scores: [ScoredCandidate]
        let selectedIndex: Int?
        let selectedHexColor: String?
        let error: Double?
        let tieBroke: Bool?
        let tiedIndices: [Int]
    }

    private struct ScoredCandidate: Decodable, Equatable {
        let index: Int
        let score: ParityScore
    }

    private enum ParityScore: Equatable {
        case score(Double)
        case excluded
    }

    private extension ParityScore: Decodable {
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                self = .score(value)
            } else if let marker = try? container.decode(String.self), marker == "excluded" {
                self = .excluded
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "expected a numeric score or \"excluded\""
                )
            }
        }

        init(_ result: ScorerResult) {
            switch result {
            case .score(let value): self = .score(value)
            case .excluded: self = .excluded
            }
        }
    }

    // MARK: - Corpus contract

    func testCorpusIsStampedWithTheCurrentAlgorithmContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
        XCTAssertEqual(corpus.scenarios.count, 12)
    }

    /// The corpus must keep exercising the interesting cases: exact ties and
    /// palettes where every candidate is excluded.
    func testCorpusContainsIntentionalTieAndNoSelectionScenarios() throws {
        let corpus = try loadCorpus()

        let tiedIDs = corpus.scenarios
            .filter { $0.expected.tieBroke == true }
            .map(\.id)
        let noSelectionIDs = corpus.scenarios
            .filter { $0.expected.selectedIndex == nil }
            .map(\.id)

        XCTAssertEqual(
            Set(tiedIDs),
            [
                "tie-symmetric-around-target",
                "tie-duplicate-vectors",
                "tie-three-way-on-lps",
                "zero-weight-channel-missing",
                "mixed-large-palette",
            ]
        )
        XCTAssertEqual(Set(noSelectionIDs), ["missing-target-excluded", "all-excluded"])
    }

    /// The corpus carries an unknown light-source weight (`ultraviolet`); like
    /// the Elixir `filter_weights` step it must be dropped, leaving weights
    /// identical to the `distinct-errors` scenario — whose expected scores the
    /// scenario then shares verbatim.
    func testUnknownLightSourceWeightsAreIgnored() throws {
        let corpus = try loadCorpus()
        let scenario = try XCTUnwrap(corpus.scenarios.first { $0.id == "unknown-weight-ignored" })
        let distinct = try XCTUnwrap(corpus.scenarios.first { $0.id == "distinct-errors" })

        XCTAssertTrue(scenario.weights.keys.contains("ultraviolet"))
        XCTAssertEqual(
            channelWeights(scenario.weights),
            ChannelWeights(white: 0.5, red: 1.0, green: 1.0, blue: 0.25, lps: 1.5)
        )
        XCTAssertEqual(
            scenario.expected.scores.sorted { $0.index < $1.index },
            distinct.expected.scores.sorted { $0.index < $1.index }
        )
    }

    // MARK: - Scenario replay

    func testReplaysEveryScenarioThroughTheScorerWithExactAgreement() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            try replayThroughScorer(scenario)
        }
    }

    /// The composition solver's fast path is what the app actually uses, so it
    /// must select the same candidate as the corpus for every scenario whose
    /// target vector the solver can represent (a target missing an
    /// active channel has no grid and is covered by the scorer replay).
    func testReplaysEveryRepresentableScenarioThroughTheSolver() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            try replayThroughSolver(scenario)
        }
    }

    // MARK: - Replay internals

    private func replayThroughScorer(_ scenario: Scenario) throws {
        let weights = channelWeights(scenario.weights)
        let scorer = WeightedSquaredErrorScorer()
        let target = targetVector(from: scenario.target)
        let palette = try self.palette(from: scenario.palette)
        let expected = scenario.expected

        XCTAssertEqual(palette.count, expected.scores.count, scenario.id)

        let scores: [ParityScore] = palette.map { color in
            ParityScore(scorer.score(candidate: color, target: target, weights: weights))
        }

        for scored in expected.scores {
            guard scored.index < scores.count else {
                return XCTFail("\(scenario.id): score index \(scored.index) out of range")
            }
            XCTAssertEqual(scores[scored.index], scored.score, "\(scenario.id): candidate \(scored.index)")
        }

        let selection = earliestWinningSelection(scores: scores)

        XCTAssertEqual(selection?.index, expected.selectedIndex, "\(scenario.id): selected index")

        guard let selected = selection else {
            XCTAssertNil(expected.error, "\(scenario.id): expected recorded error")
            XCTAssertNil(expected.tieBroke, "\(scenario.id): expected tie evidence")
            XCTAssertTrue(expected.tiedIndices.isEmpty, "\(scenario.id): expected tied indices")
            return
        }

        XCTAssertEqual(palette[selected.index].hex, expected.selectedHexColor, "\(scenario.id): selected hex color")
        XCTAssertEqual(selected.error, expected.error, "\(scenario.id): winning error")

        let tiedIndices = scores.enumerated().compactMap { entry -> Int? in
            guard case .score(let value) = entry.element, value == selected.error else { return nil }
            return entry.offset
        }
        XCTAssertEqual(tiedIndices, expected.tiedIndices, "\(scenario.id): tied indices")
        XCTAssertEqual(tiedIndices.count > 1, expected.tieBroke == true, "\(scenario.id): tie_broke")
        XCTAssertEqual(tiedIndices.first, expected.selectedIndex, "\(scenario.id): tie winner")
    }

    private func replayThroughSolver(_ scenario: Scenario) throws {
        let weights = channelWeights(scenario.weights)
        let palette = try self.palette(from: scenario.palette)

        var sourceGrids: [LightingCondition: BrightnessGrid] = [:]
        for entry in weights.activeEntries {
            guard let brightness = scenario.target.channels[entry.condition.rawValue] else { return }
            sourceGrids[entry.condition] = BrightnessGrid(width: 1, height: 1, fill: brightness)
        }

        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: sourceGrids,
            weights: weights
        )

        XCTAssertEqual(result.colorIndices.first.flatMap { $0 }, scenario.expected.selectedIndex, "\(scenario.id): solver selection")

        guard scenario.expected.selectedIndex != nil else {
            XCTAssertEqual(result.unmatchedCellCount, 1, "\(scenario.id): expected an unmatched cell")
            return
        }

        let error = try XCTUnwrap(result.errors.first, scenario.id)
        XCTAssertEqual(error, try XCTUnwrap(scenario.expected.error, scenario.id), "\(scenario.id): solver error")

        let excludedCount = scenario.expected.scores.filter { candidate in
            guard case .excluded = candidate.score else { return false }
            return true
        }.count
        XCTAssertEqual(result.excludedCandidateCount, excludedCount, "\(scenario.id): excluded candidate count")
    }

    private func earliestWinningSelection(scores: [ParityScore]) -> (index: Int, error: Double)? {
        var best: (index: Int, error: Double)?
        for (index, score) in scores.enumerated() {
            guard case .score(let value) = score else { continue }
            if value < (best?.error ?? .infinity) {
                best = (index, value)
            }
        }
        return best
    }

    private func loadCorpus() throws -> Corpus {
        let data = try Data(contentsOf: Self.corpusURL)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Corpus.self, from: data)
    }

    /// Maps the corpus weight map onto `ChannelWeights`, dropping keys that are
    /// not known lighting conditions — mirroring `WeightedSquaredError.filter_weights/1`.
    private func channelWeights(_ encoded: [String: Double]) -> ChannelWeights {
        var weights = ChannelWeights()
        for (key, value) in encoded {
            guard let condition = LightingCondition(rawValue: key) else { continue }
            switch condition {
            case .white: weights.white = value
            case .red: weights.red = value
            case .green: weights.green = value
            case .blue: weights.blue = value
            case .lps: weights.lps = value
            }
        }
        return weights
    }

    private func palette(from vectors: [Vector]) throws -> [PaletteColor] {
        try vectors
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
            .map { vector in
                let rgb = try XCTUnwrap(RGBColor(hex: vector.hexColor), "unparseable hex \(vector.hexColor)")
                var responses: [LightingCondition: IlluminationResponse] = [:]
                for (key, value) in vector.channels {
                    guard let condition = LightingCondition(rawValue: key) else { continue }
                    responses[condition] = IlluminationResponse(brightness: value)
                }
                return PaletteColor(id: vector.index ?? 0, hex: vector.hexColor, rgb: rgb, responses: responses)
            }
    }

    private func targetVector(from vector: Vector) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in vector.channels {
            guard let condition = LightingCondition(rawValue: key) else { continue }
            brightness[condition] = value
        }
        return TargetResponseVector(brightness)
    }
}
