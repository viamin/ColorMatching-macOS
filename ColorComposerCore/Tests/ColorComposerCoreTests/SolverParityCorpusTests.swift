import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    private static let corpusURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")

    func testWeightedSquaredErrorReplaysCommittedParityCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertFalse(corpus.scenarios.isEmpty)

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let data = try Data(contentsOf: Self.corpusURL)
        return try JSONDecoder().decode(ParityCorpus.self, from: data)
    }

    private func assertScenario(_ scenario: ParityScenario) throws {
        let weights = channelWeights(from: scenario.weights)
        let target = targetVector(from: scenario.target)
        let palette = try scenario.palette.sorted { $0.index < $1.index }.map(paletteColor(from:))
        let actualScores = palette.map {
            WeightedSquaredErrorScorer().score(candidate: $0, target: target, weights: weights)
        }
        let expectedScores = scenario.expected.scores.sorted { $0.index < $1.index }

        XCTAssertEqual(actualScores.count, expectedScores.count, scenario.id)
        for (actual, expected) in zip(actualScores, expectedScores) {
            assertScore(actual, matches: expected.score, scenarioID: scenario.id, index: expected.index)
        }

        let selection = selectEarliestLowestScore(from: actualScores)
        assertSelection(selection, scenario: scenario, palette: palette)
    }

    private func channelWeights(from encoded: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: encoded["white"] ?? 0,
            red: encoded["red"] ?? 0,
            green: encoded["green"] ?? 0,
            blue: encoded["blue"] ?? 0,
            lps: encoded["lps"] ?? 0
        )
    }

    private func targetVector(from vector: ParityVector) -> TargetResponseVector {
        TargetResponseVector(responses(from: vector.channels))
    }

    private func paletteColor(from vector: ParityVector) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: vector.hexColor), "Invalid parity hex: \(vector.hexColor)")
        return PaletteColor(
            id: try XCTUnwrap(vector.index, "Palette vector missing index"),
            hex: vector.hexColor,
            rgb: rgb,
            responses: responses(from: vector.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, brightness) }
        })
    }

    private func assertScore(
        _ actual: ScorerResult,
        matches expected: ParityScore,
        scenarioID: String,
        index: Int
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            return
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "\(scenarioID), index \(index)")
        default:
            XCTFail("\(scenarioID), index \(index): expected \(expected), got \(actual)")
        }
    }

    private func selectEarliestLowestScore(from scores: [ScorerResult]) -> (index: Int, error: Double)? {
        scores.enumerated().reduce(into: nil) { selection, candidate in
            guard case .score(let error) = candidate.element else { return }
            if selection == nil || error < selection!.error {
                selection = (candidate.offset, error)
            }
        }
    }

    private func assertSelection(
        _ selection: (index: Int, error: Double)?,
        scenario: ParityScenario,
        palette: [PaletteColor]
    ) {
        guard let expectedIndex = scenario.expected.selectedIndex else {
            XCTAssertNil(selection, scenario.id)
            XCTAssertNil(scenario.expected.error, scenario.id)
            XCTAssertNil(scenario.expected.tieBroke, scenario.id)
            XCTAssertTrue(scenario.expected.tiedIndices.isEmpty, scenario.id)
            return
        }

        guard let actual = selection else {
            XCTFail(scenario.id)
            return
        }
        XCTAssertEqual(actual.index, expectedIndex, scenario.id)
        XCTAssertEqual(palette[actual.index].hex, scenario.expected.selectedHexColor, scenario.id)
        XCTAssertEqual(actual.error, scenario.expected.error!, accuracy: 1e-12, scenario.id)

        let tiedIndices = palette.indices.compactMap { index -> Int? in
            if case .score(let score) = WeightedSquaredErrorScorer().score(
                candidate: palette[index], target: targetVector(from: scenario.target), weights: channelWeights(from: scenario.weights)
            ), score == actual.error {
                return index
            }
            return nil
        }
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
        XCTAssertEqual(scenario.expected.tieBroke, tiedIndices.count > 1, scenario.id)
        XCTAssertEqual(tiedIndices.first, expectedIndex, scenario.id)
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let scenarios: [ParityScenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case scorer, selection, scenarios
        case missingPolicy = "missing_policy"
    }
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?

    enum CodingKeys: String, CodingKey {
        case channels, index
        case hexColor = "hex_color"
    }
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
    case score(Double)
    case excluded

    var description: String {
        switch self {
        case .score(let value): return "\(value)"
        case .excluded: return "excluded"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .score(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected score or excluded")
        }
    }
}
