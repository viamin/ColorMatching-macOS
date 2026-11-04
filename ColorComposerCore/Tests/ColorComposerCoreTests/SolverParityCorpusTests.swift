import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesVersionOneParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            try assertScorerParity(for: scenario)
            try assertSolverParity(for: scenario)
        }
    }

    private func assertScorerParity(for scenario: Scenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let target = TargetResponseVector(channels(scenario.target.channels))
        let weights = makeWeights(scenario.weights)

        for expected in scenario.expected.scores {
            let candidate = try XCTUnwrap(scenario.palette.first { $0.index == expected.index })
            switch (scorer.score(candidate: makeColor(candidate), target: target, weights: weights), expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .value(let expected)):
                XCTAssertEqual(actual, expected, accuracy: 1e-12, "scenario: \(scenario.id), candidate: \(candidate.index)")
            default:
                XCTFail("scenario: \(scenario.id), candidate: \(candidate.index)")
            }
        }
    }

    private func assertSolverParity(for scenario: Scenario) throws {
        let active = scenario.weights.compactMap { name, weight in
            weight > 0 ? LightingCondition(rawValue: name) : nil
        }
        guard active.allSatisfy({ scenario.target.channels[$0.rawValue] != nil }) else {
            XCTAssertNil(scenario.expected.selectedIndex, "a missing active target has no solver grid")
            return
        }

        let palette = scenario.palette.sorted { $0.index! < $1.index! }.map(makeColor)
        let grids = Dictionary(uniqueKeysWithValues: active.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [scenario.target.channels[condition.rawValue]!]))
        })
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: grids,
            weights: makeWeights(scenario.weights)
        )

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, "scenario: \(scenario.id)")
        if let error = scenario.expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), error, accuracy: 1e-12, "scenario: \(scenario.id)")
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, "scenario: \(scenario.id)")
        }
        if let index = scenario.expected.selectedIndex {
            XCTAssertEqual(palette[index].hex, scenario.expected.selectedHexColor, "scenario: \(scenario.id)")
            XCTAssertEqual(index, scenario.expected.tiedIndices.min(), "scenario: \(scenario.id)")
            XCTAssertEqual(scenario.expected.tieBroke, scenario.expected.tiedIndices.count > 1, "scenario: \(scenario.id)")
        }
    }

    private func loadCorpus() throws -> Corpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }

    private func makeColor(_ candidate: Candidate) -> PaletteColor {
        PaletteColor(
            id: candidate.index!,
            hex: candidate.hexColor,
            rgb: RGBColor(hex: candidate.hexColor)!,
            responses: channels(candidate.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func channels(_ values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func makeWeights(_ values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let selection: String
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let palette: [Candidate]
    let target: Candidate
    let weights: [String: Double]
    let expected: Expected
}

private struct Candidate: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
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
    let score: ParityScore
}

private enum ParityScore: Decodable {
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
