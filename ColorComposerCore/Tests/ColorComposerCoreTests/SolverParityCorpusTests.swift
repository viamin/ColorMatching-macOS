import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesVersionOneParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let weights = makeWeights(from: scenario.weights)
        let target = TargetResponseVector(knownChannels(in: scenario.target.channels))
        let palette = try scenario.palette.map(makeColor)
        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(scenario.expected.scores.map(\.index), scenario.palette.map(\.index), scenario.id)
        XCTAssertEqual(actualScores, scenario.expected.scores.map(\.scorerResult), scenario.id)

        let actualSelection = actualScores.enumerated().reduce(nil as (index: Int, error: Double)?) { best, entry in
            guard case .score(let error) = entry.element else { return best }
            guard let best else { return (entry.offset, error) }
            return error < best.error ? (entry.offset, error) : best
        }

        XCTAssertEqual(actualSelection?.index, scenario.expected.selectedIndex, scenario.id)
        XCTAssertEqual(actualSelection?.error, scenario.expected.error, scenario.id)
        XCTAssertEqual(
            actualSelection.map { palette[$0.index].hex },
            scenario.expected.selectedHexColor,
            scenario.id
        )

        let tiedIndices = scenario.expected.error.map { expectedError in
            actualScores.enumerated().compactMap { index, result in
                result == .score(expectedError) ? index : nil
            }
        } ?? []
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
        XCTAssertEqual(tiedIndices.count > 1, scenario.expected.tieBroke ?? false, scenario.id)
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Parity/v1/corpus.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fileURL))
    }

    private func makeColor(_ fixture: ParityPaletteColor) throws -> PaletteColor {
        guard let rgb = RGBColor(hex: fixture.hexColor) else {
            throw ParityFixtureError.invalidHex(fixture.hexColor)
        }
        let responses = knownChannels(in: fixture.channels).mapValues(IlluminationResponse.init(brightness:))
        return PaletteColor(id: fixture.index, hex: fixture.hexColor, rgb: rgb, responses: responses)
    }

    private func makeWeights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func knownChannels(in values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case scorer, selection, scenarios
    }
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityPaletteColor]
    let target: ParityPaletteColor
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityPaletteColor: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int

    enum CodingKeys: String, CodingKey {
        case channels, index
        case hexColor = "hex_color"
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
    let score: ParityScoreValue

    var scorerResult: ScorerResult {
        switch score {
        case .value(let value): return .score(value)
        case .excluded: return .excluded
        }
    }
}

private enum ParityScoreValue: Decodable {
    case value(Double)
    case excluded

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

private enum ParityFixtureError: Error {
    case invalidHex(String)
}
