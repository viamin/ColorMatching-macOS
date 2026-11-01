import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the committed `color_matching` solver parity corpus
/// (`viamin/color_matching#111`, vendored at
/// `Fixtures/parity-corpus-v1.json`) against `WeightedSquaredErrorScorer` so
/// the client and server provably agree on scoring and selection, including
/// exclusions and tie-breaking. See `README.md` § "Solver parity corpus" for
/// where the corpus lives and how to refresh it.
final class SolverParityTests: XCTestCase {
    // MARK: - Corpus schema

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
        let palette: [PaletteEntry]
        let expected: Expected
    }

    private struct Vector: Decodable {
        let hexColor: String
        let channels: [String: Double]
    }

    private struct PaletteEntry: Decodable {
        let index: Int
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

    /// `score` is polymorphic on the wire: a finite number, or the literal
    /// string `"excluded"` mirroring `ScorerResult.excluded`.
    private enum ScoreValue: Decodable {
        case value(Double)
        case excluded

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                self = .value(value)
            } else {
                let string = try container.decode(String.self)
                guard string == "excluded" else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Unexpected score value: \(string)"
                    )
                }
                self = .excluded
            }
        }
    }

    // MARK: - Fixture loading

    private static let corpus: Corpus = {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parity-corpus-v1.json")
        do {
            let data = try Data(contentsOf: fixtureURL)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(Corpus.self, from: data)
        } catch {
            fatalError("Failed to load solver parity corpus fixture at \(fixtureURL.path): \(error)")
        }
    }()

    // MARK: - Domain conversion

    private func weights(from raw: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: raw["white"] ?? 0,
            red: raw["red"] ?? 0,
            green: raw["green"] ?? 0,
            blue: raw["blue"] ?? 0,
            lps: raw["lps"] ?? 0
        )
    }

    private func targetVector(from vector: Vector) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for condition in LightingCondition.allCases {
            if let value = vector.channels[condition.rawValue] {
                brightness[condition] = value
            }
        }
        return TargetResponseVector(brightness)
    }

    private func paletteColor(from entry: PaletteEntry) throws -> PaletteColor {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for condition in LightingCondition.allCases {
            if let value = entry.channels[condition.rawValue] {
                responses[condition] = IlluminationResponse(brightness: value)
            }
        }
        let rgb = try XCTUnwrap(RGBColor(hex: entry.hexColor))
        return PaletteColor(id: entry.index, hex: entry.hexColor, rgb: rgb, responses: responses)
    }

    /// Lowest-score, earliest-index-wins selection over `scores`, matching
    /// the corpus's `"earliest-index-wins"` policy and
    /// `CompositionSolver`'s tie-break rule.
    private func select(_ scores: [ScorerResult]) -> (selectedIndex: Int?, error: Double?, tiedIndices: [Int]) {
        var bestIndex: Int?
        var bestScore = Double.infinity
        for (index, result) in scores.enumerated() {
            guard case .score(let value) = result else { continue }
            if value < bestScore {
                bestScore = value
                bestIndex = index
            }
        }
        guard let bestIndex else { return (nil, nil, []) }
        let tied = scores.enumerated().compactMap { index, result -> Int? in
            guard case .score(let value) = result, value == bestScore else { return nil }
            return index
        }
        return (bestIndex, bestScore, tied)
    }

    // MARK: - Tests

    /// Guards against `/api/v1` light-source drift: the corpus's channel set
    /// must stay exactly the client's `LightingCondition` cases, in order.
    func testCorpusLightSourcesMatchLightingCondition() {
        XCTAssertEqual(Self.corpus.lightSources, LightingCondition.allCases.map(\.rawValue))
    }

    func testCorpusTargetsThisScorerAndSelectionPolicy() {
        XCTAssertEqual(Self.corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(Self.corpus.selection, "earliest-index-wins")
        XCTAssertEqual(Self.corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
    }

    func testCorpusCoversEveryScenario() throws {
        for scenario in Self.corpus.scenarios {
            try runScenario(scenario)
        }
    }

    private func runScenario(_ scenario: Scenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let channelWeights = weights(from: scenario.weights)
        let target = targetVector(from: scenario.target)
        let palette = try scenario.palette.map(paletteColor)

        XCTAssertEqual(
            palette.map(\.id), scenario.expected.scores.map(\.index),
            "palette/expectation index alignment for \(scenario.id)"
        )

        let scores = palette.map { scorer.score(candidate: $0, target: target, weights: channelWeights) }

        for (entry, result) in zip(scenario.expected.scores, scores) {
            switch (entry.score, result) {
            case (.excluded, .excluded):
                break
            case (.value(let expected), .score(let actual)):
                XCTAssertEqual(
                    actual, expected, accuracy: 1e-9,
                    "\(scenario.id) candidate \(entry.index) score"
                )
            default:
                XCTFail("\(scenario.id) candidate \(entry.index): expected \(entry.score), got \(result)")
            }
        }

        let (selectedIndex, error, tiedIndices) = select(scores)

        XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, "\(scenario.id) selected_index")
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, "\(scenario.id) tied_indices")
        XCTAssertEqual(tiedIndices.count > 1, scenario.expected.tieBroke ?? false, "\(scenario.id) tie_broke")

        if let expectedError = scenario.expected.error {
            let actualError = try XCTUnwrap(error, "\(scenario.id) expected a score but selection excluded everyone")
            XCTAssertEqual(actualError, expectedError, accuracy: 1e-9, "\(scenario.id) error")
        } else {
            XCTAssertNil(error, "\(scenario.id) expected no selectable candidate")
        }

        if let expectedHex = scenario.expected.selectedHexColor, let selectedIndex {
            XCTAssertEqual(palette[selectedIndex].hex, expectedHex, "\(scenario.id) selected_hex_color")
        } else {
            XCTAssertNil(scenario.expected.selectedHexColor, "\(scenario.id) expected no selected_hex_color")
        }
    }
}
