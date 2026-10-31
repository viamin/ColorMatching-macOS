import XCTest
@testable import ColorComposerCore

/// Solver parity against the golden-vector corpus committed by the
/// `color_matching` server (viamin/color_matching#112).
///
/// The corpus is the shared source of truth replayed by both test suites so
/// silent divergence between `WeightedSquaredErrorScorer` (plus the solver's
/// earliest-wins selection) and the Elixir `ColorMatching.WeightedSquaredError`
/// is caught. See `docs/parity-corpus.md` for where the corpus lives and how
/// to refresh it.
final class SolverParityCorpusTests: XCTestCase {
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

    /// A per-candidate score: either a finite double or `"excluded"`.
    private struct ParityScore: Decodable {
        let index: Int
        let value: Double?
        let excluded: Bool

        enum CodingKeys: String, CodingKey { case index, score }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            index = try container.decode(Int.self, forKey: .index)
            if let double = try? container.decode(Double.self, forKey: .score) {
                value = double
                excluded = false
            } else {
                value = nil
                excluded = true
            }
        }
    }

    private enum CorpusError: Error, CustomStringConvertible {
        case fixtureMissing([String])

        var description: String {
            switch self {
            case .fixtureMissing(let searched):
                return """
                Parity corpus fixture not found. Searched: \(searched). \
                Refresh it per docs/parity-corpus.md (copy priv/parity/v1/corpus.json \
                from color_matching into ColorComposerCore/Tests/Fixtures/parity/v1/).
                """
            }
        }
    }

    /// Fixture lives under `Tests/Fixtures` (outside any target directory) so it
    /// needs no Package.swift resource declaration; lookup is `#filePath`-relative
    /// and survives moving this suite into a dedicated test target under `Tests/`.
    private static func corpusURL() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let candidates = [
            directory.deletingLastPathComponent().appendingPathComponent("Fixtures/parity/v1/corpus.json"),
            directory.appendingPathComponent("Fixtures/parity/v1/corpus.json"),
        ]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw CorpusError.fixtureMissing(candidates.map(\.path))
        }
        return url
    }

    private func loadCorpus() throws -> ParityCorpus {
        let url = try Self.corpusURL()
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }

    // MARK: - Corpus contract

    func testCorpusFixtureIsCommittedWithExpectedContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1, "A bumped algorithm_version means every expectation moved; re-review before updating the fixture.")
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
        XCTAssertEqual(corpus.scenarios.count, 12)
    }

    // MARK: - Scorer parity

    func testScorerScoresMatchCorpusExactly() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let replayed = try replay(scenario)
            XCTAssertEqual(
                replayed.results.count, scenario.expected.scores.count,
                "scenario \(scenario.id): candidate count mismatch"
            )

            for expected in scenario.expected.scores {
                let result = replayed.results[expected.index]
                switch (result, expected.excluded) {
                case (.excluded, true):
                    break
                case (.score(let value), false):
                    XCTAssertEqual(
                        value, expected.value ?? .nan, accuracy: 1e-12,
                        "scenario \(scenario.id): candidate \(expected.index) score mismatch"
                    )
                default:
                    XCTFail("scenario \(scenario.id): candidate \(expected.index) expected \(expected.excluded ? "excluded" : String(describing: expected.value)) but got \(result)")
                }
            }
        }
    }

    func testEarliestWinsSelectionMatchesCorpusIncludingTies() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            let replayed = try replay(scenario)
            let winner = Self.earliestBest(replay: replayed.results)

            if scenario.expected.selectedIndex == nil {
                XCTAssertNil(winner, "scenario \(scenario.id): expected no eligible candidate")
                XCTAssertTrue(scenario.expected.tiedIndices.isEmpty, "scenario \(scenario.id)")
                continue
            }

            let best = try XCTUnwrap(winner, "scenario \(scenario.id): expected a selection")
            XCTAssertEqual(best.index, scenario.expected.selectedIndex, "scenario \(scenario.id): selected index")
            XCTAssertEqual(
                replayed.palette[best.index].hex, scenario.expected.selectedHexColor,
                "scenario \(scenario.id): selected hex"
            )
            XCTAssertEqual(best.score, scenario.expected.error ?? .nan, accuracy: 1e-12, "scenario \(scenario.id): winning error")

            let tied = Self.tiedIndices(replay: replayed.results, bestScore: best.score)
            XCTAssertEqual(tied, scenario.expected.tiedIndices, "scenario \(scenario.id): tied indices")
            XCTAssertEqual(tied.count > 1, scenario.expected.tieBroke == true, "scenario \(scenario.id): tie_broke")
        }
    }

    /// End-to-end replay through the real solver (1×1 grids) so the app's
    /// deterministic selection path — not just the scorer — matches the corpus.
    /// Scenarios whose *target* is missing a positive-weight channel cannot be
    /// expressed as source grids and are covered by the scorer tests above.
    func testSolverSingleCellSelectionMatchesCorpus() throws {
        let corpus = try loadCorpus()
        let solver = CompositionSolver()

        for scenario in corpus.scenarios {
            let replayed = try replay(scenario)
            guard replayed.weights.activeConditions.allSatisfy({ replayed.target.value(for: $0) != nil }) else {
                continue
            }
            let grids = try Self.grids(for: replayed)
            let result = try solver.solve(palette: replayed.palette, sourceGrids: grids, weights: replayed.weights)
            let selected = result.colorIndex(x: 0, y: 0)
            let excludedCount = scenario.expected.scores.filter(\.excluded).count

            XCTAssertEqual(selected, scenario.expected.selectedIndex, "scenario \(scenario.id): solver selection")
            XCTAssertEqual(result.excludedCandidateCount, excludedCount, "scenario \(scenario.id): excluded candidate count")

            if scenario.expected.selectedIndex == nil {
                XCTAssertTrue(result.errors[0].isInfinite, "scenario \(scenario.id): unmatched cell error")
            } else {
                XCTAssertEqual(result.errors[0], scenario.expected.error ?? .nan, accuracy: 1e-12, "scenario \(scenario.id): solver error")
            }
        }
    }

    // MARK: - Replay helpers

    private struct Replay {
        let palette: [PaletteColor]
        let target: TargetResponseVector
        let weights: ChannelWeights
        let results: [ScorerResult]
    }

    private func replay(_ scenario: ParityScenario) throws -> Replay {
        let weights = Self.weights(fromRaw: scenario.weights)
        let palette = try scenario.palette.enumerated().map { try Self.color(from: $0.element, index: $0.offset) }
        let target = Self.target(from: scenario.target)
        let scorer = WeightedSquaredErrorScorer()
        let results = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
        return Replay(palette: palette, target: target, weights: weights, results: results)
    }

    /// Unknown light-source keys in the corpus weights map (e.g. "ultraviolet")
    /// are silently ignored, mirroring the Elixir scorer.
    private static func weights(fromRaw raw: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: raw["white"] ?? 0,
            red: raw["red"] ?? 0,
            green: raw["green"] ?? 0,
            blue: raw["blue"] ?? 0,
            lps: raw["lps"] ?? 0
        )
    }

    private static func color(from vector: ParityVector, index: Int) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: vector.hexColor), "unparseable hex \(vector.hexColor) in corpus")
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, brightness) in vector.channels {
            if let condition = LightingCondition(rawValue: key) {
                responses[condition] = IlluminationResponse(brightness: brightness)
            }
        }
        return PaletteColor(id: index, hex: vector.hexColor, rgb: rgb, responses: responses)
    }

    private static func target(from vector: ParityVector) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in vector.channels {
            if let condition = LightingCondition(rawValue: key) {
                brightness[condition] = value
            }
        }
        return TargetResponseVector(brightness)
    }

    /// Minimum score with earliest-index tie-breaking (the corpus
    /// "earliest-index-wins" selection contract).
    private static func earliestBest(replay results: [ScorerResult]) -> (index: Int, score: Double)? {
        var best: (index: Int, score: Double)?
        for (index, result) in results.enumerated() {
            if case .score(let value) = result, best.map({ value < $0.score }) ?? true {
                best = (index, value)
            }
        }
        return best
    }

    private static func tiedIndices(replay results: [ScorerResult], bestScore: Double) -> [Int] {
        results.enumerated().compactMap { index, result in
            if case .score(let value) = result, value == bestScore { return index }
            return nil
        }
    }

    private static func grids(for replay: Replay) throws -> [LightingCondition: BrightnessGrid] {
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for (condition, _) in replay.weights.activeEntries {
            grids[condition] = BrightnessGrid(
                width: 1,
                height: 1,
                fill: try XCTUnwrap(replay.target.value(for: condition))
            )
        }
        return grids
    }
}
