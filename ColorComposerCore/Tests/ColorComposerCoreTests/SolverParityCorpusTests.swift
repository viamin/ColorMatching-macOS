import Foundation
import XCTest
@testable import ColorComposerCore

/// Solver-parity suite driven by the committed golden-vector corpus produced
/// by `viamin/color_matching` (`priv/parity/v1/corpus.json`, `mix parity.generate`).
///
/// Every scenario replays the Elixir `ColorMatching.WeightedSquaredError`
/// scorer and the earliest-wins selection of `ColorMatching.IlluminantMatching`
/// against this package's `WeightedSquaredErrorScorer` and `CompositionSolver`,
/// asserting per-candidate scores, the selected index, the selection error,
/// and tie-break evidence match the corpus exactly. See
/// `docs/solver-parity-corpus.md` for corpus provenance and refresh steps.
final class SolverParityCorpusTests: XCTestCase {
    private var corpus: ParityCorpus!

    override func setUpWithError() throws {
        try super.setUpWithError()
        corpus = try ParityCorpusLoader.load()
    }

    // MARK: - Corpus invariants

    func testCorpusDeclaresVersionOneAndCanonicalContract() throws {
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
    }

    func testCorpusCoversEveryParityCategory() throws {
        let ids = corpus.scenarios.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "scenario ids must be unique")
        XCTAssertFalse(ids.contains { $0.isEmpty })

        XCTAssert(corpus.scenarios.contains { $0.expected.tieBroke == true }, "no tie scenario")
        XCTAssert(corpus.scenarios.contains { $0.expected.selectedIndex == nil }, "no nil-selection scenario")
        XCTAssert(corpus.scenarios.contains { $0.expected.scores.contains { $0.score == .excluded } }, "no exclusion scenario")
        XCTAssert(corpus.scenarios.contains { ($0.weights["blue"] ?? 1) == 0 }, "no zero-weight scenario")
        XCTAssert(
            corpus.scenarios.contains { !Set($0.weights.keys).subtracting(corpus.lightSources).isEmpty },
            "no unknown-weight-key scenario"
        )
        XCTAssert(corpus.scenarios.contains { $0.expected.error == 0 }, "no exact-match scenario")
    }

    // MARK: - Scorer + selection parity

    func testPerCandidateScoresMatchCorpusExactly() throws {
        for scenario in corpus.scenarios {
            let palette = try paletteColors(for: scenario)
            let target = targetVector(for: scenario)
            let weights = channelWeights(for: scenario)

            for scored in scenario.expected.scores {
                let result = WeightedSquaredErrorScorer().score(
                    candidate: palette[scored.index],
                    target: target,
                    weights: weights
                )
                assertScore(result, equals: scored.score, scenario: scenario, index: scored.index)
            }
        }
    }

    func testSelectionsMatchCorpusIncludingTieBreaks() throws {
        for scenario in corpus.scenarios {
            let palette = try paletteColors(for: scenario)
            let target = targetVector(for: scenario)
            let weights = channelWeights(for: scenario)

            let best = Self.selectBest(palette: palette, target: target, weights: weights)

            XCTAssertEqual(best?.index, scenario.expected.selectedIndex, "selection mismatch in \(scenario.id)")
            if let best {
                XCTAssertEqual(palette[best.index].hex, scenario.expected.selectedHexColor, "hex mismatch in \(scenario.id)")
                XCTAssertEqual(best.score, scenario.expected.error ?? .nan, accuracy: 1e-12, "error mismatch in \(scenario.id)")
            } else {
                XCTAssertNil(scenario.expected.error, "expected no selection in \(scenario.id)")
            }
        }
    }

    func testTieEvidenceMatchesCorpus() throws {
        for scenario in corpus.scenarios {
            let palette = try paletteColors(for: scenario)
            let target = targetVector(for: scenario)
            let weights = channelWeights(for: scenario)

            let tied = Self.tiedIndices(palette: palette, target: target, weights: weights)

            XCTAssertEqual(tied, scenario.expected.tiedIndices, "tied indices mismatch in \(scenario.id)")
            XCTAssertEqual(tied.count > 1, scenario.expected.tieBroke ?? false, "tie_broke mismatch in \(scenario.id)")
        }
    }

    func testExcludedCandidatesNeverWinSelection() throws {
        for scenario in corpus.scenarios {
            let palette = try paletteColors(for: scenario)
            let target = targetVector(for: scenario)
            let weights = channelWeights(for: scenario)

            let excludedIndices = scenario.expected.scores.filter { $0.score == .excluded }.map(\.index)

            if let best = Self.selectBest(palette: palette, target: target, weights: weights) {
                XCTAssertFalse(excludedIndices.contains(best.index), "excluded candidate won in \(scenario.id)")
            } else {
                XCTAssertEqual(excludedIndices.count, palette.count, "expected all-excluded in \(scenario.id)")
            }
        }
    }

    // MARK: - Solver end-to-end parity

    /// The scorer is only half the contract: the app selects through
    /// `CompositionSolver`. Replaying each scenario as a 1×1 composition must
    /// reproduce the corpus selection through the solver's optimized path.
    func testSolverSelectsCorpusWinnerForSingleCellComposition() throws {
        for scenario in corpus.scenarios {
            let palette = try paletteColors(for: scenario)
            let target = targetVector(for: scenario)
            let weights = channelWeights(for: scenario)

            let active = weights.activeConditions
            // A target with a missing positive-weight channel can only be
            // expressed at the scorer level; the solver's grids always carry
            // values, so the all-excluded expectation cannot be replayed there.
            // Those scenarios are fully covered by the scorer-level tests above.
            guard active.allSatisfy({ target.value(for: $0) != nil }) else { continue }

            var grids: [LightingCondition: BrightnessGrid] = [:]
            for condition in active {
                grids[condition] = BrightnessGrid(width: 1, height: 1, fill: target.value(for: condition)!)
            }

            let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)

            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, "cell selection mismatch in \(scenario.id)")
            if let selectedIndex = scenario.expected.selectedIndex {
                XCTAssertEqual(result.error(x: 0, y: 0), scenario.expected.error ?? .nan, accuracy: 1e-12, "cell error mismatch in \(scenario.id)")
                XCTAssertEqual(result.palette[selectedIndex].hex, scenario.expected.selectedHexColor)
            } else {
                XCTAssertEqual(result.error(x: 0, y: 0), .infinity, accuracy: 0)
            }
            XCTAssertEqual(
                result.excludedCandidateCount,
                scenario.expected.scores.filter { $0.score == .excluded }.count,
                "excluded count mismatch in \(scenario.id)"
            )
        }
    }

    // MARK: - Selection replication (mirrors IlluminantMatching.best_match/4)

    private static func selectBest(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> (index: Int, score: Double)? {
        var best: (index: Int, score: Double)?
        for (index, color) in palette.enumerated() {
            guard case .score(let score) = WeightedSquaredErrorScorer().score(
                candidate: color, target: target, weights: weights
            ) else { continue }
            if score < (best?.score ?? .infinity) {
                best = (index, score)
            }
        }
        return best
    }

    private static func tiedIndices(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> [Int] {
        guard let best = selectBest(palette: palette, target: target, weights: weights) else { return [] }
        return palette.indices.filter { index in
            guard case .score(let score) = WeightedSquaredErrorScorer().score(
                candidate: palette[index], target: target, weights: weights
            ) else { return false }
            return score == best.score
        }
    }

    // MARK: - Corpus → domain mapping

    private func paletteColors(for scenario: ParityCorpus.Scenario) throws -> [PaletteColor] {
        try scenario.palette.enumerated().map { index, entry in
            guard let rgb = RGBColor(hex: entry.hexColor) else {
                throw XCTSkip("corpus hex \(entry.hexColor) is not parseable")
            }
            return PaletteColor(
                id: index,
                hex: entry.hexColor,
                rgb: rgb,
                responses: responses(entry.channels)
            )
        }
    }

    private func targetVector(for scenario: ParityCorpus.Scenario) -> TargetResponseVector {
        TargetResponseVector(brightnessMap(scenario.target.channels))
    }

    private func channelWeights(for scenario: ParityCorpus.Scenario) -> ChannelWeights {
        var weights = ChannelWeights()
        for (key, value) in scenario.weights {
            switch LightingCondition(rawValue: key) {
            case .white: weights.white = value
            case .red: weights.red = value
            case .green: weights.green = value
            case .blue: weights.blue = value
            case .lps: weights.lps = value
            case nil: break // Unknown light sources are filtered, mirroring Elixir filter_weights/1.
            }
        }
        return weights
    }

    private func responses(_ channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, value) in channels {
            if let condition = LightingCondition(rawValue: key) {
                responses[condition] = IlluminationResponse(brightness: value)
            }
        }
        return responses
    }

    private func brightnessMap(_ channels: [String: Double]) -> [LightingCondition: Double] {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in channels {
            if let condition = LightingCondition(rawValue: key) {
                brightness[condition] = value
            }
        }
        return brightness
    }

    private func assertScore(
        _ result: ScorerResult,
        equals expected: ParityCorpus.ScoreValue,
        scenario: ParityCorpus.Scenario,
        index: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (result, expected) {
        case let (.score(actual), .score(expectedValue)):
            XCTAssertEqual(actual, expectedValue, accuracy: 1e-12, "score mismatch in \(scenario.id) at index \(index)", file: file, line: line)
        case (.excluded, .excluded):
            break
        default:
            XCTFail("kind mismatch in \(scenario.id) at index \(index): got \(result), want \(expected)", file: file, line: line)
        }
    }
}

// MARK: - Corpus wire format

/// Codable view of the committed corpus JSON (snake_case wire keys).
struct ParityCorpus: Codable {
    struct Scenario: Codable {
        struct Entry: Codable {
            let index: Int?
            let hexColor: String
            let channels: [String: Double]
        }
        struct Expected: Codable {
            struct ScoredEntry: Codable {
                let index: Int
                let score: ScoreValue
            }
            let scores: [ScoredEntry]
            let selectedIndex: Int?
            let selectedHexColor: String?
            let error: Double?
            let tieBroke: Bool?
            let tiedIndices: [Int]
        }
        let id: String
        let description: String
        let weights: [String: Double]
        let target: Entry
        let palette: [Entry]
        let expected: Expected
    }

    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scorer: String
    let selection: String
    let scenarios: [Scenario]
}

/// A corpus score is either a float or the literal string "excluded".
enum ScoreValue: Codable, Equatable, CustomStringConvertible {
    case score(Double)
    case excluded

    var description: String {
        switch self {
        case .score(let value): return ".score(\(value))"
        case .excluded: return ".excluded"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self), string == "excluded" {
            self = .excluded
        } else {
            self = .score(try container.decode(Double.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .score(let value): try container.encode(value)
        case .excluded: try container.encode("excluded")
        }
    }
}

// MARK: - Fixture loading

enum ParityCorpusError: Error, LocalizedError {
    case fixtureMissing(String)

    var errorDescription: String? {
        switch self {
        case .fixtureMissing(let searched):
            return "Parity corpus fixture not found. Searched: \(searched). See docs/solver-parity-corpus.md for the refresh procedure."
        }
    }
}

enum ParityCorpusLoader {
    static let fixtureFileName = "parity-v1-corpus.json"

    static func load() throws -> ParityCorpus {
        let data = try Data(contentsOf: fixtureURL())
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: data)
    }

    /// Resolves the committed fixture: from the test bundle once the fixture
    /// is declared as a package resource, otherwise next to this source file.
    static func fixtureURL() throws -> URL {
        let bundle = Bundle(for: BundleAnchor.self)
        let bundleURLs = [
            bundle.url(forResource: "parity-v1-corpus", withExtension: "json"),
            bundle.url(forResource: "parity-v1-corpus", withExtension: "json", subdirectory: "Fixtures")
        ].compactMap { $0 }
        if let bundled = bundleURLs.first {
            return bundled
        }

        let sourceRelative = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(fixtureFileName)")
        if FileManager.default.fileExists(atPath: sourceRelative.path) {
            return sourceRelative
        }

        throw ParityCorpusError.fixtureMissing(
            bundle.bundlePath + ", " + sourceRelative.path
        )
    }
}

/// Anchor for bundle lookup; never instantiated.
private final class BundleAnchor {}
