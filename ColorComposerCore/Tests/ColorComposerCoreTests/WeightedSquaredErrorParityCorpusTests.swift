import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testReplaysUpstreamParityCorpusExactly() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertParity(scenario)
        }
    }

    private func assertParity(_ scenario: ParityScenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let weights = makeWeights(scenario.weights)
        let target = TargetResponseVector(makeChannels(scenario.target.channels))
        let palette = try scenario.palette.map(makeColor)

        for expectedScore in scenario.expected.scores {
            let result = scorer.score(
                candidate: palette[expectedScore.index], target: target, weights: weights
            )
            switch (result, expectedScore.value) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .score(let expected)):
                XCTAssertEqual(actual, expected, "scenario=\(scenario.id), index=\(expectedScore.index)")
            default:
                XCTFail("scenario=\(scenario.id), index=\(expectedScore.index): expected \(expectedScore.value), got \(result)")
            }
        }

        let selected = select(palette, target: target, weights: weights, scorer: scorer)
        XCTAssertEqual(selected?.index, scenario.expected.selectedIndex, "scenario=\(scenario.id)")
        XCTAssertEqual(selected?.color.hex, scenario.expected.selectedHexColor, "scenario=\(scenario.id)")
        XCTAssertEqual(selected?.error, scenario.expected.error, "scenario=\(scenario.id)")

        let tied = scenario.expected.scores.compactMap { score -> Int? in
            score.value.numeric == scenario.expected.error ? score.index : nil
        }
        XCTAssertEqual(tied, scenario.expected.tiedIndices, "scenario=\(scenario.id)")
        XCTAssertEqual(scenario.expected.tieBroke, tied.count > 1, "scenario=\(scenario.id)")

        try assertSolverSelection(
            scenario, palette: palette, weights: weights, expectedIndex: scenario.expected.selectedIndex
        )
    }

    private func assertSolverSelection(
        _ scenario: ParityScenario,
        palette: [PaletteColor],
        weights: ChannelWeights,
        expectedIndex: Int?
    ) throws {
        let active = weights.activeEntries
        guard active.allSatisfy({ scenario.target.channels[$0.condition.rawValue] != nil }) else {
            return
        }

        let grids = Dictionary(uniqueKeysWithValues: active.map { entry in
            (entry.condition, BrightnessGrid(width: 1, height: 1, values: [scenario.target.channels[entry.condition.rawValue]!]))
        })
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)
        XCTAssertEqual(result.colorIndex(x: 0, y: 0), expectedIndex, "scenario=\(scenario.id)")
        XCTAssertEqual(result.error(x: 0, y: 0), scenario.expected.error, "scenario=\(scenario.id)")
    }

    private func select(
        _ palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights,
        scorer: WeightedSquaredErrorScorer
    ) -> (index: Int, color: PaletteColor, error: Double)? {
        var best: (index: Int, color: PaletteColor, error: Double)?
        for (index, color) in palette.enumerated() {
            guard case .score(let error) = scorer.score(candidate: color, target: target, weights: weights) else { continue }
            if best == nil || error < best!.error {
                best = (index, color, error)
            }
        }
        return best
    }

    private func loadCorpus() throws -> ParityCorpus {
        let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = sourceDirectory.appendingPathComponent("Fixtures/parity-v1-corpus.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
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

    private func makeChannels(_ values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func makeColor(_ vector: ParityVector) throws -> PaletteColor {
        guard let rgb = RGBColor(hex: vector.hexColor) else {
            throw ParityFixtureError.invalidHex(vector.hexColor)
        }
        return PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: rgb,
            responses: makeChannels(vector.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let selection: String
    let missingPolicy: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: ParityVector
    let palette: [ParityVector]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let value: ParityScoreValue

    private enum CodingKeys: String, CodingKey {
        case index
        case value = "score"
    }
}

private enum ParityScoreValue: Decodable {
    case excluded
    case score(Double)

    var numeric: Double? {
        guard case .score(let value) = self else { return nil }
        return value
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let marker = try? value.decode(String.self), marker == "excluded" {
            self = .excluded
        } else {
            self = .score(try value.decode(Double.self))
        }
    }
}

private enum ParityFixtureError: Error {
    case invalidHex(String)
}
