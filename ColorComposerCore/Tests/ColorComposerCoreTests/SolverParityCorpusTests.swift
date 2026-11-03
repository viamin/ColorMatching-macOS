import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedParityCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.scenarios.count, 12)

        for scenario in corpus.scenarios {
            try assertScorerParity(for: scenario)
            try assertSolverSelectionParity(for: scenario)
        }
    }

    private func assertScorerParity(for scenario: Scenario, file: StaticString = #filePath, line: UInt = #line) throws {
        let scorer = WeightedSquaredErrorScorer()
        let target = TargetResponseVector(channels(for: scenario.target.channels))
        let weights = channelWeights(for: scenario.weights)

        for expectedScore in scenario.expected.scores {
            let candidate = try XCTUnwrap(
                scenario.palette.first(where: { $0.index == expectedScore.index }),
                "Corpus score references an unknown palette index",
                file: file,
                line: line
            )

            XCTAssertEqual(
                scorer.score(candidate: paletteColor(for: candidate), target: target, weights: weights),
                scorerResult(for: expectedScore.score),
                "Scenario: \(scenario.id), candidate: \(candidate.index)",
                file: file,
                line: line
            )
        }
    }

    private func assertSolverSelectionParity(for scenario: Scenario, file: StaticString = #filePath, line: UInt = #line) throws {
        let weights = channelWeights(for: scenario.weights)
        let targetChannels = channels(for: scenario.target.channels)

        guard weights.activeConditions.allSatisfy({ targetChannels[$0] != nil }) else {
            XCTAssertNil(scenario.expected.selectedIndex, "A missing required target channel cannot select a color", file: file, line: line)
            XCTAssertNil(scenario.expected.error, "A missing required target channel cannot have a score", file: file, line: line)
            return
        }

        let sourceGrids = Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, fill: targetChannels[condition]!))
        })
        let palette = scenario.palette.map { paletteColor(for: $0) }
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: sourceGrids, weights: weights)

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, "Scenario: \(scenario.id)", file: file, line: line)
        if let expectedError = scenario.expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, "Scenario: \(scenario.id)", file: file, line: line)
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, "Scenario: \(scenario.id)", file: file, line: line)
        }

        if let selectedIndex = scenario.expected.selectedIndex {
            XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor, "Scenario: \(scenario.id)", file: file, line: line)
            if scenario.expected.tieBroke == true {
                XCTAssertEqual(selectedIndex, scenario.expected.tiedIndices.min(), "Scenario: \(scenario.id)", file: file, line: line)
            }
        }
    }

    private func loadCorpus() throws -> Corpus {
        let sourceURL = URL(fileURLWithPath: #filePath)
        let corpusURL = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: corpusURL))
    }

    private func paletteColor(for fixture: PaletteFixture) -> PaletteColor {
        PaletteColor(
            id: fixture.index,
            hex: fixture.hexColor,
            rgb: RGBColor(hex: fixture.hexColor)!,
            responses: channels(for: fixture.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func channels(for values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { name, value in
            lightingCondition(named: name).map { ($0, value) }
        })
    }

    private func channelWeights(for values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func scorerResult(for score: CorpusScore) -> ScorerResult {
        switch score {
        case .excluded:
            .excluded
        case .value(let value):
            .score(value)
        }
    }

    private func lightingCondition(named name: String) -> LightingCondition? {
        switch name {
        case "white": .white
        case "red": .red
        case "green": .green
        case "blue": .blue
        case "lps": .lps
        default: nil
        }
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [Scenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case missingPolicy = "missing_policy"
        case scenarios
    }
}

private struct Scenario: Decodable {
    let id: String
    let palette: [PaletteFixture]
    let target: TargetFixture
    let weights: [String: Double]
    let expected: Expected
}

private struct PaletteFixture: Decodable {
    let index: Int
    let hexColor: String
    let channels: [String: Double]

    enum CodingKeys: String, CodingKey {
        case index
        case hexColor = "hex_color"
        case channels
    }
}

private struct TargetFixture: Decodable {
    let channels: [String: Double]
}

private struct Expected: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]

    enum CodingKeys: String, CodingKey {
        case error
        case scores
        case selectedHexColor = "selected_hex_color"
        case selectedIndex = "selected_index"
        case tieBroke = "tie_broke"
        case tiedIndices = "tied_indices"
    }
}

private struct ExpectedScore: Decodable {
    let index: Int
    let score: CorpusScore
}

private enum CorpusScore: Decodable {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Score must be a number or excluded")
        }
    }
}
