import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testReplaysCommittedServerParityCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
        XCTAssertFalse(corpus.scenarios.isEmpty)
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: ParityScenario) throws {
        let palette = try scenario.palette
            .sorted { $0.index < $1.index }
            .map(makeColor)
        let target = TargetResponseVector(knownChannels(from: scenario.target.channels))
        let weights = makeWeights(scenario.weights)
        let scores = palette.map { WeightedSquaredErrorScorer().score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(scores.count, scenario.expected.scores.count, scenario.id)
        for (actual, expected) in zip(scores, scenario.expected.scores.sorted { $0.index < $1.index }) {
            switch (actual, expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .value(let expected)):
                XCTAssertEqual(actual, expected, scenario.id)
            default:
                XCTFail("\(scenario.id): score did not match corpus")
            }
        }

        let selected = selection(from: scores)
        XCTAssertEqual(selected?.index, scenario.expected.selectedIndex, scenario.id)
        XCTAssertEqual(selected?.score, scenario.expected.error, scenario.id)

        let tiedIndices = scores.enumerated().compactMap { index, score -> Int? in
            guard case .score(let value) = score, value == selected?.score else { return nil }
            return index
        }
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
        let tieBroke: Bool? = selected == nil ? nil : tiedIndices.count > 1
        XCTAssertEqual(scenario.expected.tieBroke, tieBroke, scenario.id)

        if let selectedIndex = selected?.index {
            XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor, scenario.id)
        }

        try assertSolverSelectionWhenTargetIsComplete(
            scenario,
            palette: palette,
            weights: weights,
            expectedIndex: scenario.expected.selectedIndex,
            expectedError: scenario.expected.error
        )
    }

    private func assertSolverSelectionWhenTargetIsComplete(
        _ scenario: ParityScenario,
        palette: [PaletteColor],
        weights: ChannelWeights,
        expectedIndex: Int?,
        expectedError: Double?
    ) throws {
        let activeConditions = weights.activeConditions
        guard activeConditions.allSatisfy({ scenario.target.channels[$0.rawValue] != nil }) else { return }

        let grids = Dictionary(uniqueKeysWithValues: activeConditions.map {
            ($0, BrightnessGrid(width: 1, height: 1, values: [scenario.target.channels[$0.rawValue]!]))
        })
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), expectedIndex, scenario.id)
        XCTAssertEqual(result.error(x: 0, y: 0), expectedError ?? .infinity, scenario.id)
    }

    private func selection(from scores: [ScorerResult]) -> (index: Int, score: Double)? {
        scores.enumerated().reduce(nil) { best, entry in
            guard case .score(let score) = entry.element else { return best }
            guard let best else { return (entry.offset, score) }
            return score < best.score ? (entry.offset, score) : best
        }
    }

    private func makeColor(_ vector: ParityVector) throws -> PaletteColor {
        let responses = knownChannels(from: vector.channels).mapValues(IlluminationResponse.init(brightness:))
        return PaletteColor(
            id: vector.index ?? 0,
            hex: vector.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: vector.hexColor)),
            responses: responses
        )
    }

    private func knownChannels(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func makeWeights(_ weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white"] ?? 0,
            red: weights["red"] ?? 0,
            green: weights["green"] ?? 0,
            blue: weights["blue"] ?? 0,
            lps: weights["lps"] ?? 0
        )
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testDirectory.appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: url))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scenarios: [ParityScenario]
    let scorer: String
    let selection: String
}

private struct ParityScenario: Decodable {
    let expected: ParityExpected
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
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
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    enum Value: Equatable {
        case excluded
        case value(Double)
    }

    let index: Int
    let score: Value

    private enum CodingKeys: String, CodingKey {
        case index
        case score
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        if let value = try? container.decode(Double.self, forKey: .score) {
            score = .value(value)
        } else {
            let marker = try container.decode(String.self, forKey: .score)
            guard marker == "excluded" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .score,
                    in: container,
                    debugDescription: "Expected a numeric score or the excluded marker"
                )
            }
            score = .excluded
        }
    }
}
