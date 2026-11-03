import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testCommittedParityCorpusMatchesScoresSelectionsAndTies() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })

        for scenario in corpus.scenarios {
            assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: ParityScenario) {
        let scorer = WeightedSquaredErrorScorer()
        let weights = ChannelWeights(channels: scenario.weights)
        let target = TargetResponseVector(scenario.target.responses)
        let palette = scenario.palette.sorted { $0.index < $1.index }.map(\\.paletteColor)
        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
        for (actual, expected) in zip(actualScores, scenario.expected.scores.sorted { $0.index < $1.index }) {
            switch (actual, expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actualScore), .value(let expectedScore)):
                XCTAssertEqual(actualScore, expectedScore, scenario.id)
            default:
                XCTFail("\\(scenario.id): score/exclusion mismatch")
            }
        }

        let selection = selectedIndex(in: actualScores)
        XCTAssertEqual(selection, scenario.expected.selectedIndex, scenario.id)
        if let selection {
            guard let expectedHex = scenario.expected.selectedHexColor,
                  let expectedError = scenario.expected.error,
                  let expectedTieBroke = scenario.expected.tieBroke else {
                return XCTFail("\\(scenario.id): selected scenario has incomplete expectations")
            }
            XCTAssertEqual(palette[selection].hex, expectedHex, scenario.id)
            guard case .score(let error) = actualScores[selection] else {
                return XCTFail("\\(scenario.id): selected candidate is excluded")
            }
            XCTAssertEqual(error, expectedError, scenario.id)
            let ties = actualScores.enumerated().compactMap { index, result -> Int? in
                guard case .score(let score) = result, score == error else { return nil }
                return index
            }
            XCTAssertEqual(ties, scenario.expected.tiedIndices, scenario.id)
            XCTAssertEqual(ties.count > 1, expectedTieBroke, scenario.id)
        } else {
            XCTAssertNil(scenario.expected.error, scenario.id)
            XCTAssertNil(scenario.expected.tieBroke, scenario.id)
            XCTAssertTrue(scenario.expected.tiedIndices.isEmpty, scenario.id)
        }
    }

    private func selectedIndex(in scores: [ScorerResult]) -> Int? {
        var selection: Int?
        var bestError = Double.infinity
        for (index, result) in scores.enumerated() {
            guard case .score(let error) = result, error < bestError else { continue }
            bestError = error
            selection = index
        }
        return selection
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpectation
}

private struct ParityVector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]

    var responses: [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    var paletteColor: PaletteColor {
        PaletteColor(
            id: index ?? -1,
            hex: hexColor,
            rgb: RGBColor(hex: hexColor)!,
            responses: responses.mapValues(IlluminationResponse.init(brightness:))
        )
    }
}

private struct ParityExpectation: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ExpectedScore
}

private enum ExpectedScore: Decodable {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else {
            let value = try container.decode(String.self)
            guard value == "excluded" else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected a numeric score or excluded"
                )
            }
            self = .excluded
        }
    }
}

private extension ChannelWeights {
    init(channels: [String: Double]) {
        self.init(
            white: channels["white"] ?? 0,
            red: channels["red"] ?? 0,
            green: channels["green"] ?? 0,
            blue: channels["blue"] ?? 0,
            lps: channels["lps"] ?? 0
        )
    }
}
