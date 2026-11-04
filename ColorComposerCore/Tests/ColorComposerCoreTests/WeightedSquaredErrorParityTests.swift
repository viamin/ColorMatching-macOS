import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testMatchesCommittedV1ParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            assertMatchesExpectedResult(for: scenario)
        }
    }

    private func assertMatchesExpectedResult(for scenario: ParityScenario) {
        let scorer = WeightedSquaredErrorScorer()
        let weights = ChannelWeights(channels: scenario.weights)
        let target = TargetResponseVector(scenario.target.channels.lightingValues)
        let candidates = scenario.palette.map(ParityCandidate.paletteColor)
        let scores = candidates.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(scores.count, scenario.expected.scores.count, scenario.id)
        for (actual, expected) in zip(scores, scenario.expected.scores) {
            XCTAssertEqual(actual, expected.scorerResult, scenario.id + " candidate " + String(expected.index))
        }

        let selection = scores.enumerated().compactMap { index, score -> (Int, Double)? in
            guard case .score(let value) = score else { return nil }
            return (index, value)
        }.min { left, right in
            left.1 == right.1 ? left.0 < right.0 : left.1 < right.1
        }

        XCTAssertEqual(selection?.0, scenario.expected.selectedIndex, scenario.id)
        if let expectedError = scenario.expected.error {
            guard let selection else {
                return XCTFail("Expected a selection for \(scenario.id)")
            }
            XCTAssertEqual(selection.1, expectedError, accuracy: 1e-12, scenario.id)
        } else {
            XCTAssertNil(selection, scenario.id)
        }
        XCTAssertEqual(selection.map { candidates[$0.0].hex }, scenario.expected.selectedHexColor, scenario.id)
        XCTAssertEqual(
            scores.enumerated().compactMap { index, score in
                guard case .score(let value) = score, value == selection?.1 else { return nil }
                return index
            },
            scenario.expected.tiedIndices,
            scenario.id
        )
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testDirectory.appendingPathComponent("Fixtures/ParityCorpus/v1/corpus.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let selection: String
    let missingPolicy: String
    let scenarios: [ParityScenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case selection
        case missingPolicy = "missing_policy"
        case scenarios
    }
}

private struct ParityScenario: Decodable {
    let id: String
    let weights: ParityChannels
    let target: ParityCandidate
    let palette: [ParityCandidate]
    let expected: ParityExpectation
}

private struct ParityCandidate: Decodable {
    let index: Int?
    let hexColor: String
    let channels: ParityChannels

    enum CodingKeys: String, CodingKey {
        case index
        case hexColor = "hex_color"
        case channels
    }

    func paletteColor() -> PaletteColor {
        PaletteColor(
            id: index ?? -1,
            hex: hexColor,
            rgb: RGBColor(hex: hexColor)!,
            responses: channels.lightingValues.mapValues(IlluminationResponse.init(brightness:))
        )
    }
}

private struct ParityChannels: Decodable {
    let white: Double?
    let red: Double?
    let green: Double?
    let blue: Double?
    let lps: Double?

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

private extension ChannelWeights {
    init(channels: ParityChannels) {
        self.init(
            white: channels.white ?? 0,
            red: channels.red ?? 0,
            green: channels.green ?? 0,
            blue: channels.blue ?? 0,
            lps: channels.lps ?? 0
        )
    }
}

private struct ParityExpectation: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tiedIndices: [Int]

    enum CodingKeys: String, CodingKey {
        case error
        case scores
        case selectedHexColor = "selected_hex_color"
        case selectedIndex = "selected_index"
        case tiedIndices = "tied_indices"
    }
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ScoreValue

    var scorerResult: ScorerResult {
        switch score {
        case .value(let value): return .score(value)
        case .excluded: return .excluded
        }
    }
}

private enum ScoreValue: Decodable {
    case value(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected score or excluded")
        }
    }
}
