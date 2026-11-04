import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedV1Corpus() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let corpus = try decoder.decode(ParityCorpus.self, from: Data(contentsOf: corpusURL))
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let weights = channelWeights(from: scenario.weights)
            let target = TargetResponseVector(channels(from: scenario.target.channels))
            let actualScores = scenario.palette.map { entry in
                score(scorer, candidate: paletteColor(from: entry), target: target, weights: weights)
            }
            let expectedScores = scenario.expected.scores.map(\.score)

            XCTAssertEqual(actualScores, expectedScores, scenario.id)

            let selected = actualScores.enumerated().first { _, score in
                score.value == actualScores.compactMap(\.value).min()
            }
            XCTAssertEqual(selected?.offset, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(selected.map { scenario.palette[$0.offset].hexColor }, scenario.expected.selectedHexColor, scenario.id)
            XCTAssertEqual(selected?.element.value, scenario.expected.error, scenario.id)

            let tiedIndices = actualScores.enumerated().compactMap { index, score in
                score.value == selected?.element.value ? index : nil
            }
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
            XCTAssertEqual(tiedIndices.count > 1 ? true : nil, scenario.expected.tieBroke, scenario.id)
        }
    }

    private var corpusURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
    }

    private func score(
        _ scorer: WeightedSquaredErrorScorer,
        candidate: PaletteColor,
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> ExpectedScore {
        switch scorer.score(candidate: candidate, target: target, weights: weights) {
        case .excluded: return .excluded
        case .score(let value): return .value(value)
        }
    }

    private func paletteColor(from entry: ParityVector) -> PaletteColor {
        PaletteColor(
            id: entry.index ?? -1,
            hex: entry.hexColor,
            rgb: RGBColor(hex: entry.hexColor)!,
            responses: channels(from: entry.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func channels(from values: [String: Double]) -> [LightingCondition: Double] {
        values.reduce(into: [:]) { channels, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            channels[condition] = entry.value
        }
    }

    private func channelWeights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
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
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ExpectedScore
}

private enum ExpectedScore: Decodable, Equatable {
    case excluded
    case value(Double)

    var value: Double? {
        if case .value(let value) = self { return value }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else {
            XCTAssertEqual(try container.decode(String.self), "excluded")
            self = .excluded
        }
    }
}
