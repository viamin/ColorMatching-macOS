import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testCommittedParityCorpusMatchesScoresSelectionsAndTieEvidence() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })

        for scenario in corpus.scenarios {
            assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: ParityScenario) {
        let scorer = WeightedSquaredErrorScorer()
        let weights = scenario.weights.channelWeights
        let target = scenario.target.targetResponseVector
        let palette = scenario.palette.map(\.paletteColor)
        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
        for (index, pair) in zip(actualScores, scenario.expected.scores.sorted { $0.index < $1.index }).enumerated() {
            let (actual, expected) = pair
            XCTAssertEqual(expected.index, index, scenario.id)
            assertScore(actual, equals: expected.score, scenarioID: scenario.id)
        }

        let selected = selectedIndex(from: actualScores)
        XCTAssertEqual(selected, scenario.expected.selectedIndex, scenario.id)
        if let selected {
            XCTAssertEqual(palette[selected].hex, scenario.expected.selectedHexColor, scenario.id)
            guard case .score(let score) = actualScores[selected] else {
                return XCTFail("\(scenario.id): selected candidate was excluded")
            }
            guard let expectedError = scenario.expected.error else {
                return XCTFail("\(scenario.id): selected candidate has no expected error")
            }
            XCTAssertEqual(score, expectedError, scenario.id)
        }

        let tiedIndices = tiedIndices(in: actualScores, at: scenario.expected.error)
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
        if let selected {
            XCTAssertEqual(scenario.expected.tieBroke, tiedIndices.count > 1, scenario.id)
            XCTAssertEqual(selected, tiedIndices.first, scenario.id)
        } else {
            XCTAssertNil(scenario.expected.tieBroke, scenario.id)
        }
    }

    private func assertScore(_ actual: ScorerResult, equals expected: ParityScore, scenarioID: String) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, scenarioID)
        default:
            XCTFail("\(scenarioID): score result differs from corpus")
        }
    }

    private func selectedIndex(from scores: [ScorerResult]) -> Int? {
        scores.enumerated().reduce(into: nil as (index: Int, score: Double)?) { best, entry in
            guard case .score(let score) = entry.element else { return }
            if best == nil || score < best!.score {
                best = (entry.offset, score)
            }
        }?.index
    }

    private func tiedIndices(in scores: [ScorerResult], at expectedError: Double?) -> [Int] {
        guard let expectedError else { return [] }
        return scores.enumerated().compactMap { index, result in
            guard case .score(let score) = result, score == expectedError else { return nil }
            return index
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("weighted-squared-error-parity-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }
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
    let palette: [ParityVector]
    let target: ParityVector
    let weights: ParityChannels
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: ParityChannels

    var targetResponseVector: TargetResponseVector {
        TargetResponseVector(channels.lightingValues)
    }

    var paletteColor: PaletteColor {
        PaletteColor(
            id: index ?? -1,
            hex: hexColor,
            rgb: RGBColor(hex: hexColor)!,
            responses: channels.lightingValues.mapValues { IlluminationResponse(brightness: $0) }
        )
    }
}

private struct ParityChannels: Decodable {
    let white: Double?
    let red: Double?
    let green: Double?
    let blue: Double?
    let lps: Double?

    var channelWeights: ChannelWeights {
        ChannelWeights(white: white ?? 0, red: red ?? 0, green: green ?? 0, blue: blue ?? 0, lps: lps ?? 0)
    }

    var lightingValues: [LightingCondition: Double] {
        [
            .white: white,
            .red: red,
            .green: green,
            .blue: blue,
            .lps: lps
        ].compactMapValues { $0 }
    }
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityExpectedScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable {
    case excluded
    case score(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .score(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown parity score")
        }
    }
}
