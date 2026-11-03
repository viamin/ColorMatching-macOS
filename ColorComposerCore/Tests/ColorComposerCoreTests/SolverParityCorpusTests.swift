import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)

        for scenario in corpus.scenarios {
            try assertScoresMatch(scenario)
            try assertSelectionMatches(scenario)
        }
    }

    private func assertScoresMatch(_ scenario: Scenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let weights = scenario.weights.asChannelWeights
        let target = scenario.target.asTargetVector
        let expectedScores = Dictionary(
            uniqueKeysWithValues: scenario.expected.scores.map { ($0.index, $0.score) }
        )

        for paletteEntry in scenario.palette {
            guard let expected = expectedScores[paletteEntry.index] else {
                return XCTFail("Missing expected score for \\(scenario.id) candidate \\(paletteEntry.index)")
            }
            switch (scorer.score(candidate: paletteEntry.asPaletteColor, target: target, weights: weights), expected) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .number(let expected)):
                XCTAssertEqual(actual, expected, "\\(scenario.id) candidate \\(paletteEntry.index)")
            default:
                XCTFail("\\(scenario.id) candidate \\(paletteEntry.index) did not match expected \\(expected)")
            }
        }
    }

    private func assertSelectionMatches(_ scenario: Scenario) throws {
        let weights = scenario.weights.asChannelWeights
        let target = scenario.target.asTargetVector
        let scores = scenario.palette.map {
            WeightedSquaredErrorScorer().score(candidate: $0.asPaletteColor, target: target, weights: weights)
        }

        let selected = firstLowestScore(in: scores)
        XCTAssertEqual(selected, scenario.expected.selectedIndex, "\\(scenario.id) selection")

        if let selected {
            let selectedColor = scenario.palette[selected]
            guard let expectedHexColor = scenario.expected.selectedHexColor,
                  let expectedError = scenario.expected.error,
                  let expectedTieBroke = scenario.expected.tieBroke
            else {
                return XCTFail("\\(scenario.id) is missing selection evidence")
            }
            XCTAssertEqual(selectedColor.hexColor, expectedHexColor, "\\(scenario.id) selected color")
            guard case .score(let actualError) = scores[selected] else {
                return XCTFail("\\(scenario.id) selected an excluded candidate")
            }
            XCTAssertEqual(actualError, expectedError, "\\(scenario.id) selected error")

            let tied = scores.enumerated().compactMap { index, score -> Int? in
                guard case .score(let score), score == actualError else { return nil }
                return index
            }
            XCTAssertEqual(tied, scenario.expected.tiedIndices, "\\(scenario.id) tie indices")
            XCTAssertEqual(tied.count > 1, expectedTieBroke, "\\(scenario.id) tie evidence")
        } else {
            XCTAssertNil(scenario.expected.error, "\\(scenario.id) error")
            XCTAssertTrue(scenario.expected.tiedIndices.isEmpty, "\\(scenario.id) tie indices")
            XCTAssertNil(scenario.expected.tieBroke, "\\(scenario.id) tie evidence")
        }
    }

    private func firstLowestScore(in scores: [ScorerResult]) -> Int? {
        var selected: Int?
        var lowest = Double.infinity
        for (index, result) in scores.enumerated() {
            guard case .score(let score) = result, score < lowest else { continue }
            lowest = score
            selected = index
        }
        return selected
    }

    private func loadCorpus() throws -> Corpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: fixture))
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let palette: [CorpusVector]
    let target: CorpusVector
    let weights: CorpusChannels
    let expected: Expected
}

private struct CorpusVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?

    var asPaletteColor: PaletteColor {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (name, brightness) in channels {
            guard let condition = LightingCondition(rawValue: name) else { continue }
            responses[condition] = IlluminationResponse(brightness: brightness)
        }
        return PaletteColor(
            id: index ?? -1,
            hex: hexColor,
            rgb: RGBColor(hex: hexColor)!,
            responses: responses
        )
    }

    var asTargetVector: TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (name, value) in channels {
            guard let condition = LightingCondition(rawValue: name) else { continue }
            brightness[condition] = value
        }
        return TargetResponseVector(brightness)
    }
}

private struct CorpusChannels: Decodable {
    let white: Double?
    let red: Double?
    let green: Double?
    let blue: Double?
    let lps: Double?

    var asChannelWeights: ChannelWeights {
        ChannelWeights(
            white: white ?? 0,
            red: red ?? 0,
            green: green ?? 0,
            blue: blue ?? 0,
            lps: lps ?? 0
        )
    }
}

private struct Expected: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ExpectedScore: Decodable {
    let index: Int
    let score: ExpectedScoreValue
}

private enum ExpectedScoreValue: Decodable, CustomStringConvertible {
    case number(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let marker = try? container.decode(String.self), marker == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }

    var description: String {
        switch self {
        case .number(let value): return String(value)
        case .excluded: return "excluded"
        }
    }
}
