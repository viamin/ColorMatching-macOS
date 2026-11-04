import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesServerParityCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let weights = ChannelWeights(channels: scenario.weights)
        let target = TargetResponseVector(scenario.target.channels.lightingResponses)
        let palette = scenario.palette.map(PaletteColor.init)
        let scorer = WeightedSquaredErrorScorer()

        XCTAssertEqual(
            scenario.expected.scores.map(\.index),
            Array(palette.indices),
            "Corpus palette indexes must match their positions for \(scenario.id)"
        )

        for expectation in scenario.expected.scores {
            let result = scorer.score(
                candidate: palette[expectation.index],
                target: target,
                weights: weights
            )
            assert(result, matches: expectation.score, scenarioID: scenario.id, index: expectation.index)
        }

        guard let expectedIndex = scenario.expected.selectedIndex else {
            XCTAssertNil(scenario.expected.error, "Unselected scenario must not record an error: \(scenario.id)")
            XCTAssertTrue(
                scenario.expected.scores.allSatisfy { expectation in
                    if case .excluded = expectation.score { return true }
                    return false
                },
                "Unselected scenario must exclude every candidate: \(scenario.id)"
            )
            return
        }

        let sourceGrids = try sourceGrids(for: scenario, weights: weights)
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: sourceGrids,
            weights: weights
        )

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), expectedIndex, "Wrong selection for \(scenario.id)")
        XCTAssertEqual(palette[expectedIndex].hex, scenario.expected.selectedHexColor)
        XCTAssertEqual(result.error(x: 0, y: 0), scenario.expected.error!, accuracy: 1e-12)

        let tiedIndexes = scenario.expected.scores.compactMap { expectation -> Int? in
            guard case .value(let score) = expectation.score,
                  score == scenario.expected.error else { return nil }
            return expectation.index
        }
        XCTAssertEqual(tiedIndexes, scenario.expected.tiedIndices, "Wrong tie evidence for \(scenario.id)")
        XCTAssertEqual(expectedIndex, tiedIndexes.first, "Ties must select the earliest palette entry: \(scenario.id)")
    }

    private func sourceGrids(
        for scenario: ParityScenario,
        weights: ChannelWeights
    ) throws -> [LightingCondition: BrightnessGrid] {
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for condition in weights.activeConditions {
            guard let value = scenario.target.channels[condition.rawValue] else {
                throw ParityCorpusError.missingTargetChannel(scenario.id, condition)
            }
            grids[condition] = BrightnessGrid(width: 1, height: 1, values: [value])
        }
        return grids
    }

    private func assert(
        _ result: ScorerResult,
        matches expected: ExpectedScore,
        scenarioID: String,
        index: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (result, expected) {
        case (.excluded, .excluded):
            return
        case (.score(let actual), .value(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "Wrong score for \(scenarioID) candidate \(index)", file: file, line: line)
        default:
            XCTFail("Wrong exclusion result for \(scenarioID) candidate \(index)", file: file, line: line)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parity/v1/corpus.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: file))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityColor]
    let target: ParityColor
    let weights: [String: Double]
    let expected: ParityExpectation
}

private struct ParityColor: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ParityExpectation: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
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
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }
}

private enum ParityCorpusError: Error {
    case missingTargetChannel(String, LightingCondition)
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

private extension Dictionary where Key == String, Value == Double {
    var lightingResponses: [LightingCondition: Double] {
        reduce(into: [:]) { responses, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            responses[condition] = entry.value
        }
    }
}

private extension PaletteColor {
    init(_ corpusColor: ParityColor) {
        self.init(
            id: corpusColor.index ?? -1,
            hex: corpusColor.hexColor,
            rgb: RGBColor(hex: corpusColor.hexColor)!,
            responses: corpusColor.channels.lightingResponses.mapValues(IlluminationResponse.init(brightness:))
        )
    }
}
