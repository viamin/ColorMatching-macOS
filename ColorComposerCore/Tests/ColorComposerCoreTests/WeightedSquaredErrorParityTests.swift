import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    private let scorer = WeightedSquaredErrorScorer()

    func testCorpusMetadataAndRequiredCoverage() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.scores.contains { $0.score == nil } })
    }

    func testWeightedSquaredErrorMatchesParityCorpusExactly() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: ParityScenario) throws {
        let palette = try scenario.palette.sorted { $0.index < $1.index }.map(makeColor)
        let target = TargetResponseVector(try responses(from: scenario.target.channels))
        let weights = makeWeights(scenario.weights)
        let expected = scenario.expected
        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(actualScores.count, expected.scores.count, scenario.id)
        for (actual, expectedScore) in zip(actualScores, expected.scores.sorted { $0.index < $1.index }) {
            switch (actual, expectedScore.score) {
            case (.excluded, nil):
                break
            case (.score(let actual), .some(let expected)):
                XCTAssertEqual(actual, expected, scenario.id)
            default:
                XCTFail("\(scenario.id): expected \(String(describing: expectedScore.score)), got \(actual)")
            }
        }

        assertSelection(actualScores, expected: expected, palette: palette, scenarioID: scenario.id)
        assertTieEvidence(actualScores, expected: expected, scenarioID: scenario.id)
    }

    private func assertSelection(
        _ scores: [ScorerResult],
        expected: ParityExpected,
        palette: [PaletteColor],
        scenarioID: String
    ) {
        let selection = scores.enumerated().first { _, score in
            if case .score = score { return true }
            return false
        }
        XCTAssertEqual(selection?.offset, expected.selectedIndex, scenarioID)

        guard let selectedIndex = expected.selectedIndex else {
            return
        }

        XCTAssertEqual(palette[selectedIndex].hex, expected.selectedHexColor, scenarioID)
        guard case .some(.score(let error)) = selection?.element,
              let expectedError = expected.error
        else {
            return XCTFail("\(scenarioID): expected a selected score")
        }
        XCTAssertEqual(error, expectedError, scenarioID)
    }

    private func assertTieEvidence(
        _ scores: [ScorerResult],
        expected: ParityExpected,
        scenarioID: String
    ) {
        guard let error = expected.error else {
            XCTAssertNil(expected.tieBroke, scenarioID)
            XCTAssertEqual(expected.tiedIndices, [], scenarioID)
            return
        }

        let tiedIndices = scores.enumerated().compactMap { index, score -> Int? in
            guard case .score(let value) = score, value == error else { return nil }
            return index
        }
        XCTAssertEqual(tiedIndices, expected.tiedIndices, scenarioID)
        XCTAssertEqual(expected.tieBroke, tiedIndices.count > 1, scenarioID)
        XCTAssertEqual(tiedIndices.first, expected.selectedIndex, scenarioID)
    }

    private func makeColor(_ vector: ParityVector) throws -> PaletteColor {
        PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: vector.hexColor)),
            responses: try responses(from: vector.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func responses(from channels: [String: Double]) throws -> [LightingCondition: Double] {
        try Dictionary(uniqueKeysWithValues: channels.compactMap { name, value in
            guard let condition = LightingCondition(rawValue: name) else {
                XCTAssertEqual(name, "ultraviolet", "Unexpected corpus channel")
                return nil
            }
            return (condition, value)
        })
    }

    private func makeWeights(_ weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white"] ?? 0,
            red: weights["red"] ?? 0,
            green: weights["green"] ?? 0,
            blue: weights["blue"] ?? 0,
            lps: weights["lps"] ?? 0
        )
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parity-v1-corpus.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let scenarios: [ParityScenario]
    let scorer: String
    let selection: String

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case lightSources = "light_sources"
        case scenarios, scorer, selection
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
        case channels
        case hexColor = "hex_color"
        case index
    }
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
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

private struct ParityScore: Decodable {
    let index: Int
    let score: Double?
}
