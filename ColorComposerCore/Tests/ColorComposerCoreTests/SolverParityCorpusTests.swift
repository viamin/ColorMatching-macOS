import XCTest
@testable import ColorComposerCore

/// Verifies `WeightedSquaredErrorScorer` (and the selection policy documented
/// on `CompositionSolver`: lowest score wins, earliest-candidate tie-breaking)
/// against the solver parity corpus published by `color_matching`
/// (`priv/parity/v1/corpus.json`, viamin/color_matching#111).
///
/// `Fixtures/solver_parity_corpus.json` is a verbatim copy of that file. See
/// `docs/solver-parity-corpus.md` for where it lives upstream and how to
/// refresh it.
final class SolverParityCorpusTests: XCTestCase {
    private static let corpus = loadCorpus()

    private static func loadCorpus() -> ParityCorpus? {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver_parity_corpus.json")
        guard let data = try? Data(contentsOf: fixtureURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(ParityCorpus.self, from: data)
    }

    private func requireCorpus() throws -> ParityCorpus {
        try XCTUnwrap(Self.corpus, "Could not load/decode the solver parity corpus fixture")
    }

    func testCorpusFixtureDecodes() throws {
        let corpus = try requireCorpus()
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertFalse(corpus.scenarios.isEmpty)
    }

    /// Scorer-level parity: every candidate's score (or exclusion) in every
    /// scenario must match the corpus exactly, including the deliberately
    /// crafted tie cases.
    func testEveryScenarioScoreMatchesWeightedSquaredErrorScorer() throws {
        let corpus = try requireCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let weights = Self.weights(from: scenario.weights)
            let target = Self.targetVector(from: scenario.target)
            let palette = scenario.palette.map(Self.paletteColor(from:))

            var observedScores: [Int: ScorerResult] = [:]
            for (vector, color) in zip(scenario.palette, palette) {
                guard let index = vector.index else { continue }
                observedScores[index] = scorer.score(candidate: color, target: target, weights: weights)
            }

            for expectedScore in scenario.expected.scores {
                guard let observed = observedScores[expectedScore.index] else {
                    XCTFail("\(scenario.id): no observed score for candidate \(expectedScore.index)")
                    continue
                }
                assertMatches(observed, expectedScore.score, scenario: scenario.id, candidateIndex: expectedScore.index)
            }
        }
    }

    /// Selection-level parity: the chosen candidate, its error, and the tied
    /// index set must match the corpus exactly under earliest-wins
    /// tie-breaking.
    func testEveryScenarioSelectionMatchesEarliestWinsPolicy() throws {
        let corpus = try requireCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let weights = Self.weights(from: scenario.weights)
            let target = Self.targetVector(from: scenario.target)
            let palette = scenario.palette.map(Self.paletteColor(from:))

            let scored = Self.scoredCandidates(palette: palette, target: target, weights: weights, scorer: scorer)
            let selection = Self.bestMatch(among: scored)
            let tiedIndices = Self.tiedIndices(among: scored)

            XCTAssertEqual(selection?.index, scenario.expected.selectedIndex, "\(scenario.id): selected index")
            XCTAssertEqual(selection?.hex, scenario.expected.selectedHexColor, "\(scenario.id): selected hex color")
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, "\(scenario.id): tied indices")
            if let expectedTieBroke = scenario.expected.tieBroke {
                XCTAssertEqual(tiedIndices.count > 1, expectedTieBroke, "\(scenario.id): tie_broke")
            }

            if let expectedError = scenario.expected.error {
                let observedError = try XCTUnwrap(selection?.score, "\(scenario.id): expected a selection with an error")
                XCTAssertEqual(observedError, expectedError, accuracy: 1e-9, "\(scenario.id): selection error")
            } else {
                XCTAssertNil(selection, "\(scenario.id): expected no selection (all candidates excluded)")
            }
        }
    }

    /// Integration-level parity: scenarios whose target has a measurement for
    /// every active channel can be run through the production
    /// `CompositionSolver` (as a 1x1 grid) rather than just the scorer, so the
    /// corpus also exercises the real selection code path, not a
    /// reimplementation of its tie-break policy.
    func testApplicableScenariosMatchCompositionSolver() throws {
        let corpus = try requireCorpus()
        let solver = CompositionSolver(scorer: WeightedSquaredErrorScorer())

        for scenario in corpus.scenarios {
            let weights = Self.weights(from: scenario.weights)
            let active = weights.activeEntries.map(\.condition)
            guard active.allSatisfy({ scenario.target.channels[$0.rawValue] != nil }) else {
                continue // Covered by the scorer-level test instead (e.g. "missing-target-excluded").
            }

            let palette = scenario.palette.map(Self.paletteColor(from:))
            var sourceGrids: [LightingCondition: BrightnessGrid] = [:]
            for condition in active {
                let value = try XCTUnwrap(scenario.target.channels[condition.rawValue])
                sourceGrids[condition] = BrightnessGrid(width: 1, height: 1, fill: value)
            }

            let result = try solver.solve(palette: palette, sourceGrids: sourceGrids, weights: weights)
            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, "\(scenario.id): solver selected index")

            if let expectedError = scenario.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-9, "\(scenario.id): solver error")
            } else {
                XCTAssertEqual(result.error(x: 0, y: 0), .infinity, "\(scenario.id): solver error")
            }

            let expectedExcludedCount = scenario.expected.scores.filter { $0.score == .excluded }.count
            XCTAssertEqual(result.excludedCandidateCount, expectedExcludedCount, "\(scenario.id): excluded candidate count")
        }
    }

    // MARK: - Assertion helpers

    private func assertMatches(
        _ observed: ScorerResult,
        _ expected: ParityScoreValue,
        scenario: String,
        candidateIndex: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (observed, expected) {
        case (.excluded, .excluded):
            return
        case (.score(let observedValue), .value(let expectedValue)):
            XCTAssertEqual(
                observedValue, expectedValue, accuracy: 1e-9,
                "\(scenario): candidate \(candidateIndex) score", file: file, line: line
            )
        default:
            XCTFail(
                "\(scenario): candidate \(candidateIndex) exclusion mismatch (observed \(observed), expected \(expected))",
                file: file, line: line
            )
        }
    }

    // MARK: - Corpus → domain conversion

    private static func weights(from raw: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: raw["white"] ?? 0,
            red: raw["red"] ?? 0,
            green: raw["green"] ?? 0,
            blue: raw["blue"] ?? 0,
            lps: raw["lps"] ?? 0
        )
    }

    private static func targetVector(from vector: ParityVector) -> TargetResponseVector {
        TargetResponseVector(brightness(from: vector.channels))
    }

    private static func paletteColor(from vector: ParityVector) -> PaletteColor {
        PaletteColor(
            id: vector.index ?? 0,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor) ?? RGBColor(red: 0, green: 0, blue: 0),
            responses: brightness(from: vector.channels).reduce(into: [:]) { result, pair in
                result[pair.key] = IlluminationResponse(brightness: pair.value)
            }
        )
    }

    private static func brightness(from channels: [String: Double]) -> [LightingCondition: Double] {
        var result: [LightingCondition: Double] = [:]
        for (key, value) in channels {
            guard let condition = LightingCondition(rawValue: key) else { continue }
            result[condition] = value
        }
        return result
    }

    // MARK: - Selection policy under test

    private static func scoredCandidates(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights,
        scorer: CompositionScorer
    ) -> [(index: Int, hex: String, score: Double)] {
        palette.enumerated().compactMap { index, color in
            guard case .score(let score) = scorer.score(candidate: color, target: target, weights: weights) else { return nil }
            return (index, color.hex, score)
        }
    }

    /// Lowest score, earliest-candidate tie-breaking — mirrors
    /// `CompositionSolver`'s documented selection policy.
    private static func bestMatch(
        among scored: [(index: Int, hex: String, score: Double)]
    ) -> (index: Int, hex: String, score: Double)? {
        var best: (index: Int, hex: String, score: Double)?
        for candidate in scored {
            if let current = best {
                if candidate.score < current.score { best = candidate }
            } else {
                best = candidate
            }
        }
        return best
    }

    private static func tiedIndices(
        among scored: [(index: Int, hex: String, score: Double)]
    ) -> [Int] {
        guard let lowest = scored.map(\.score).min() else { return [] }
        return scored.filter { abs($0.score - lowest) < 1e-9 }.map(\.index).sorted()
    }
}

// MARK: - Corpus schema

/// Decodable mirror of `priv/parity/v1/corpus.json`'s top-level shape.
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
    let expected: ParityExpectation
}

private struct ParityVector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpectation: Decodable {
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

/// A corpus score is either a finite `Double` or the literal string
/// `"excluded"`.
private enum ParityScoreValue: Decodable, Equatable, CustomStringConvertible {
    case value(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
            return
        }
        guard try container.decode(String.self) == "excluded" else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a number or \"excluded\"")
        }
        self = .excluded
    }

    var description: String {
        switch self {
        case .value(let value): return "\(value)"
        case .excluded: return "excluded"
        }
    }
}
