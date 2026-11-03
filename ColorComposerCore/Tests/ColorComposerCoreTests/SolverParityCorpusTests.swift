import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    private let scorer = WeightedSquaredErrorScorer()

    func testCommittedParityCorpusHasTheExpectedSolverContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })
    }

    func testWeightedSquaredErrorSelectionsMatchCommittedParityCorpus() throws {
        for scenario in try loadCorpus().scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(
        for scenario: ParityCorpus.Scenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let weights = makeWeights(from: scenario.weights)
        let target = makeTarget(from: scenario.target)
        let palette = try scenario.palette
            .sorted { $0.index < $1.index }
            .map(makeColor)

        let scores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
        XCTAssertEqual(scores.count, scenario.expected.scores.count, scenario.id, file: file, line: line)

        for (actual, expected) in zip(scores, scenario.expected.scores.sorted { $0.index < $1.index }) {
            switch (actual, expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .value(let expected)):
                XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario.id, file: file, line: line)
            default:
                XCTFail("\(scenario.id): score at index \(expected.index) disagrees with corpus", file: file, line: line)
            }
        }

        guard let expectedError = scenario.expected.error else {
            XCTAssertNil(scenario.expected.selectedIndex, scenario.id, file: file, line: line)
            XCTAssertNil(scenario.expected.selectedHexColor, scenario.id, file: file, line: line)
            XCTAssertNil(scenario.expected.tieBroke, scenario.id, file: file, line: line)
            XCTAssertEqual(scenario.expected.tiedIndices, [], scenario.id, file: file, line: line)
            XCTAssertNil(scores.enumerated().first { _, score in
                if case .score = score { return true }
                return false
            }, scenario.id, file: file, line: line)
            return
        }

        let selected = scores.enumerated().first { _, score in
            if case .score(let value) = score {
                return value == expectedError
            }
            return false
        }

        XCTAssertEqual(selected?.offset, scenario.expected.selectedIndex, scenario.id, file: file, line: line)
        if let selected {
            XCTAssertEqual(palette[selected.offset].hex, scenario.expected.selectedHexColor, scenario.id, file: file, line: line)
            guard case .score(let error) = selected.element else {
                return XCTFail("\(scenario.id): selected result must be a score", file: file, line: line)
            }
            XCTAssertEqual(error, expectedError, accuracy: 1e-12, scenario.id, file: file, line: line)
        }

        let tiedIndices = scores.enumerated().compactMap { index, score -> Int? in
            guard case .score(let value) = score, value == expectedError else { return nil }
            return index
        }
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id, file: file, line: line)
        XCTAssertEqual(tiedIndices.count > 1, scenario.expected.tieBroke ?? false, scenario.id, file: file, line: line)
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let data = try Data(contentsOf: fixture)
        return try JSONDecoder().decode(ParityCorpus.self, from: data)
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

    private func makeTarget(from vector: ParityCorpus.Vector) -> TargetResponseVector {
        TargetResponseVector(responses(from: vector.channels))
    }

    private func makeColor(_ vector: ParityCorpus.Vector) throws -> PaletteColor {
        guard let rgb = RGBColor(hex: vector.hexColor) else {
            throw ParityCorpusError.invalidHex(vector.hexColor)
        }
        return PaletteColor(
            id: vector.index ?? 0,
            hex: vector.hexColor,
            rgb: rgb,
            responses: responses(from: vector.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }
}

private enum ParityCorpusError: Error {
    case invalidHex(String)
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
    let scenarios: [Scenario]

    struct Scenario: Decodable {
        let id: String
        let weights: [String: Double]
        let target: Vector
        let palette: [Vector]
        let expected: Expected
    }

    struct Vector: Decodable {
        let channels: [String: Double]
        let hexColor: String
        let index: Int?
    }

    struct Expected: Decodable {
        let error: Double?
        let scores: [Score]
        let selectedHexColor: String?
        let selectedIndex: Int?
        let tieBroke: Bool?
        let tiedIndices: [Int]
    }

    struct Score: Decodable {
        let index: Int
        let score: Value

        enum Value: Decodable {
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
    }
}

