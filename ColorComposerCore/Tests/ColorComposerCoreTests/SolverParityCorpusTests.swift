import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    private let scorer = WeightedSquaredErrorScorer()

    func testCommittedParityCorpusReplaysWeightedScoresAndSelections() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: ParityScenario) throws {
        let weights = makeWeights(scenario.weights)
        let target = TargetResponseVector(makeResponses(scenario.target.channels).mapValues(\.brightness))
        let palette = scenario.palette
            .sorted { $0.index < $1.index }
            .map(makeColor)

        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
        for (actual, expected) in zip(actualScores, scenario.expected.scores.sorted { $0.index < $1.index }) {
            assertScore(actual, equals: expected.score, scenarioID: scenario.id)
        }

        // CompositionSolver rejects a missing source grid before it can build a
        // target; the scorer corpus nevertheless specifies its direct missing-
        // target exclusion behavior, which the score assertions above cover.
        guard weights.activeConditions.allSatisfy({ target.value(for: $0) != nil }) else {
            XCTAssertNil(scenario.expected.selectedIndex, scenario.id)
            XCTAssertNil(scenario.expected.error, scenario.id)
            XCTAssertEqual(scenario.expected.tiedIndices, [], scenario.id)
            XCTAssertNil(scenario.expected.tieBroke, scenario.id)
            return
        }

        let sourceGrids = Dictionary(uniqueKeysWithValues: target.brightness.map {
            ($0.key, BrightnessGrid(width: 1, height: 1, values: [$0.value]))
        })
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: sourceGrids, weights: weights)

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
        XCTAssertEqual(result.error(x: 0, y: 0), scenario.expected.error ?? .infinity, accuracy: 1e-12, scenario.id)
        XCTAssertEqual(
            result.colorIndex(x: 0, y: 0).map { palette[$0].hex },
            scenario.expected.selectedHexColor,
            scenario.id
        )
        XCTAssertEqual(tiedIndices(in: actualScores, selectedError: scenario.expected.error), scenario.expected.tiedIndices, scenario.id)
        let expectedTieBroke = scenario.expected.selectedIndex == nil
            ? nil
            : scenario.expected.tiedIndices.count > 1
        XCTAssertEqual(scenario.expected.tieBroke, expectedTieBroke, scenario.id)
    }

    private func assertScore(_ actual: ScorerResult, equals expected: ParityScore, scenarioID: String) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .value(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, scenarioID)
        default:
            XCTFail("\(scenarioID): expected \(expected), got \(actual)")
        }
    }

    private func tiedIndices(in scores: [ScorerResult], selectedError: Double?) -> [Int] {
        guard let selectedError else { return [] }
        return scores.enumerated().compactMap { index, score in
            guard case .score(let value) = score, value == selectedError else { return nil }
            return index
        }
    }

    private func makeColor(_ vector: ParityVector) -> PaletteColor {
        PaletteColor(
            id: vector.index,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: makeResponses(vector.channels)
        )
    }

    private func makeResponses(_ channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, IlluminationResponse(brightness: brightness)) }
        })
    }

    private func makeWeights(_ weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights[LightingCondition.white.rawValue] ?? 0,
            red: weights[LightingCondition.red.rawValue] ?? 0,
            green: weights[LightingCondition.green.rawValue] ?? 0,
            blue: weights[LightingCondition.blue.rawValue] ?? 0,
            lps: weights[LightingCondition.lps.rawValue] ?? 0
        )
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scenarios: [ParityScenario]
    let selection: String

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case lightSources = "light_sources"
        case missingPolicy = "missing_policy"
        case scenarios, selection
    }
}

private struct ParityScenario: Decodable {
    let expected: ParityExpected
    let id: String
    let palette: [ParityVector]
    let target: ParityTarget
    let weights: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]

    enum CodingKeys: String, CodingKey {
        case error, scores
        case selectedHexColor = "selected_hex_color"
        case selectedIndex = "selected_index"
        case tieBroke = "tie_broke"
        case tiedIndices = "tied_indices"
    }
}

private struct ParityExpectedScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable, CustomStringConvertible {
    case excluded
    case value(Double)

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .value(let value): return String(value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int

    enum CodingKeys: String, CodingKey {
        case channels
        case hexColor = "hex_color"
        case index
    }
}

private struct ParityTarget: Decodable {
    let channels: [String: Double]
}
