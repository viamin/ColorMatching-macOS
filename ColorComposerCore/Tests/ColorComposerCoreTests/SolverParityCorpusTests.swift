import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCanonicalParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            let target = TargetResponseVector(scenario.target.channels.lightingValues)
            let weights = ChannelWeights(channels: scenario.weights)
            let palette = try scenario.palette.map { try $0.makePaletteColor() }
            let expectedScores = Dictionary(uniqueKeysWithValues: scenario.expected.scores.map { ($0.index, $0.score) })
            let actual = select(palette: palette, target: target, weights: weights)

            XCTAssertEqual(actual.excludedCount, scenario.expected.excludedCandidateCount, scenario.id)
            XCTAssertEqual(actual.selectedIndex, scenario.expected.selectedIndex, scenario.id)
            assertError(actual.error, equals: scenario.expected.error, named: scenario.id)

            for (paletteIndex, score) in actual.scores.enumerated() {
                XCTAssertEqual(palette[paletteIndex].id, scenario.palette[paletteIndex].index, scenario.id)
                assertScore(score, equals: expectedScores[palette[paletteIndex].id], named: scenario.id)
            }

            assertTieBreak(scenario.expected, actual: actual, named: scenario.id)
        }
    }

    private func select(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> Selection {
        let scorer = WeightedSquaredErrorScorer()
        var selectedIndex: Int?
        var error: Double?
        var scores: [ParityScore] = []
        var excludedCount = 0

        for color in palette {
            switch scorer.score(candidate: color, target: target, weights: weights) {
            case .excluded:
                scores.append(.excluded)
                excludedCount += 1
            case .score(let score):
                scores.append(.value(score))
                if error == nil || score < error! {
                    selectedIndex = color.id
                    error = score
                }
            }
        }

        return Selection(
            selectedIndex: selectedIndex,
            error: error,
            scores: scores,
            excludedCount: excludedCount
        )
    }

    private func assertTieBreak(_ expected: ParityExpected, actual: Selection, named scenario: String) {
        guard expected.tieBroke == true else { return }
        XCTAssertGreaterThan(expected.tiedIndices.count, 1, scenario)
        XCTAssertEqual(actual.selectedIndex, expected.tiedIndices.first, scenario)
    }

    private func assertError(_ actual: Double?, equals expected: Double?, named scenario: String) {
        switch (actual, expected) {
        case (nil, nil):
            break
        case let (.some(actual), .some(expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario)
        default:
            XCTFail("Selection error mismatch for \(scenario)")
        }
    }

    private func assertScore(_ actual: ParityScore, equals expected: ParityScore?, named scenario: String) {
        switch (actual, expected) {
        case (.excluded, .some(.excluded)):
            break
        case let (.value(actual), .some(.value(expected))):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario)
        default:
            XCTFail("Score mismatch for \(scenario): actual \(actual), expected \(String(describing: expected))")
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixtureURL = testFile
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }
}

private struct Selection {
    let selectedIndex: Int?
    let error: Double?
    let scores: [ParityScore]
    let excludedCount: Int
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [ParityScenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case missingPolicy = "missing_policy"
        case scenarios
    }
}

private struct ParityScenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: ParityVector
    let palette: [ParityPaletteColor]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
}

private struct ParityPaletteColor: Decodable {
    let index: Int
    let hexColor: String
    let channels: [String: Double]

    enum CodingKeys: String, CodingKey {
        case index
        case hexColor = "hex_color"
        case channels
    }

}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]

    enum CodingKeys: String, CodingKey {
        case error
        case scores
        case selectedIndex = "selected_index"
        case tieBroke = "tie_broke"
        case tiedIndices = "tied_indices"
    }

    var excludedCandidateCount: Int {
        scores.filter { $0.score == .excluded }.count
    }
}

private struct ParityExpectedScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable, Equatable {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown parity score")
        }
    }
}

private enum ParityCorpusError: Error {
    case invalidHexColor(String)
}

private extension ParityPaletteColor {
    func makePaletteColor() throws -> PaletteColor {
        guard let rgb = RGBColor(hex: hexColor) else {
            throw ParityCorpusError.invalidHexColor(hexColor)
        }
        return PaletteColor(
            id: index,
            hex: hexColor,
            rgb: rgb,
            responses: channels.lightingValues.reduce(into: [:]) { result, response in
                result[response.key] = IlluminationResponse(brightness: response.value)
            }
        )
    }
}

private extension Dictionary where Key == String, Value == Double {
    var lightingValues: [LightingCondition: Double] {
        reduce(into: [:]) { result, entry in
            if let condition = LightingCondition(parityName: entry.key) {
                result[condition] = entry.value
            }
        }
    }
}

private extension ChannelWeights {
    init(channels: [String: Double]) {
        self.init(
            white: channels["white", default: 0],
            red: channels["red", default: 0],
            green: channels["green", default: 0],
            blue: channels["blue", default: 0],
            lps: channels["lps", default: 0]
        )
    }
}

private extension LightingCondition {
    init?(parityName: String) {
        switch parityName {
        case "white": self = .white
        case "red": self = .red
        case "green": self = .green
        case "blue": self = .blue
        case "lps": self = .lps
        default: return nil
        }
    }
}
