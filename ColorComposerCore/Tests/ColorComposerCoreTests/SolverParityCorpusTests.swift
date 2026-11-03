import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertParity(scenario)
        }
    }

    private func assertParity(_ scenario: ParityScenario) throws {
        let palette = try scenario.palette.enumerated().map { offset, vector in
            let index = try XCTUnwrap(vector.index, "\(scenario.id): palette candidate is missing its index")
            XCTAssertEqual(index, offset, "\(scenario.id): corpus palette order changed")
            return try paletteColor(from: vector, index: index)
        }
        let target = targetVector(from: scenario.target.channels)
        let weights = weights(from: scenario.weights)
        let scorer = WeightedSquaredErrorScorer()

        for expectedScore in scenario.expected.scores {
            let candidate = try XCTUnwrap(
                palette[safe: expectedScore.index],
                "\(scenario.id): expected score references missing candidate \(expectedScore.index)"
            )
            switch (scorer.score(candidate: candidate, target: target, weights: weights), expectedScore.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .value(let expected)):
                XCTAssertEqual(actual, expected, "\(scenario.id): candidate \(expectedScore.index) score")
            default:
                XCTFail("\(scenario.id): candidate \(expectedScore.index) exclusion disagrees with corpus")
            }
        }

        let activeConditions = weights.activeConditions
        guard activeConditions.allSatisfy({ target.value(for: $0) != nil }) else {
            XCTAssertNil(scenario.expected.selectedIndex, "\(scenario.id): incomplete target must not select a color")
            return
        }

        let sourceGrids = try Dictionary(uniqueKeysWithValues: activeConditions.map { condition in
            let brightness = try XCTUnwrap(target.value(for: condition))
            return (condition, BrightnessGrid(width: 1, height: 1, values: [brightness]))
        })
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: sourceGrids,
            weights: weights
        )

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, "\(scenario.id): selection")
        if let expectedError = scenario.expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, "\(scenario.id): selected error")
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, "\(scenario.id): all candidates should be excluded")
        }

        if let selectedIndex = scenario.expected.selectedIndex {
            XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor, "\(scenario.id): selected color")
            let tiedIndices = scenario.expected.scores.compactMap { expectedScore -> Int? in
                guard case .value(let score) = expectedScore.score, score == scenario.expected.error else { return nil }
                return expectedScore.index
            }
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, "\(scenario.id): tied candidates")
            XCTAssertEqual(selectedIndex, tiedIndices.min(), "\(scenario.id): earliest candidate must win a tie")
            XCTAssertEqual(scenario.expected.tieBroke, tiedIndices.count > 1, "\(scenario.id): tie evidence")
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parity/v1/corpus.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func paletteColor(from vector: ParityVector, index: Int) throws -> PaletteColor {
        PaletteColor(
            id: index,
            hex: vector.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: vector.hexColor)),
            responses: responseVector(from: vector.channels)
        )
    }

    private func targetVector(from channels: [String: Double]) -> TargetResponseVector {
        TargetResponseVector(brightnessVector(from: channels))
    }

    private func responseVector(from channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        brightnessVector(from: channels).mapValues(IlluminationResponse.init(brightness:))
    }

    private func brightnessVector(from channels: [String: Double]) -> [LightingCondition: Double] {
        channels.reduce(into: [:]) { result, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            result[condition] = entry.value
        }
    }

    private func weights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0],
            red: values["red", default: 0],
            green: values["green", default: 0],
            blue: values["blue", default: 0],
            lps: values["lps", default: 0]
        )
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ParityScoreValue
}

private enum ParityScoreValue: Decodable {
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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
