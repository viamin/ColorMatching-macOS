import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testMatchesColorMatchingParityCorpusExactly() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = TargetResponseVector(scenario.target.channels.lightingValues)
            let weights = scenario.weights.channelWeights
            let palette = try scenario.palette.map(makePaletteColor)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
            for (index, pair) in zip(actualScores.indices, zip(actualScores, scenario.expected.scores)) {
                let (actual, expected) = pair
                XCTAssertEqual(expected.index, index, scenario.id)
                switch (actual, expected.score) {
                case (.excluded, .excluded):
                    break
                case (.score(let actual), .value(let expected)):
                    XCTAssertEqual(actual, expected, accuracy: 0, scenario.id)
                default:
                    XCTFail("\(scenario.id): expected \(expected.score), got \(actual)")
                }
            }

            let selected = earliestBestIndex(in: actualScores)
            XCTAssertEqual(selected, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(selected.map { palette[$0].hex }, scenario.expected.selectedHexColor, scenario.id)

            let tiedIndices = tiedBestIndices(in: actualScores)
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
            if let tieBroke = scenario.expected.tieBroke {
                XCTAssertEqual(tiedIndices.count > 1, tieBroke, scenario.id)
            } else {
                XCTAssertNil(selected, scenario.id)
            }
            XCTAssertEqual(selected.flatMap { actualScores[$0].value }, scenario.expected.error, scenario.id)
        }
    }

    private func loadCorpus() throws -> Corpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Corpus.self, from: Data(contentsOf: url))
    }

    private func makePaletteColor(_ color: CorpusPaletteColor) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: color.hexColor), "Invalid fixture color \(color.hexColor)")
        return PaletteColor(
            id: color.index,
            hex: color.hexColor,
            rgb: rgb,
            responses: color.channels.lightingValues.mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func earliestBestIndex(in scores: [ScorerResult]) -> Int? {
        var winner: (index: Int, score: Double)?
        for (index, result) in scores.enumerated() {
            guard case .score(let score) = result else { continue }
            if winner == nil || score < winner!.score {
                winner = (index, score)
            }
        }
        return winner?.index
    }

    private func tiedBestIndices(in scores: [ScorerResult]) -> [Int] {
        guard let best = earliestBestIndex(in: scores).flatMap({ scores[$0].value }) else { return [] }
        return scores.indices.filter { scores[$0].value == best }
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let scenarios: [CorpusScenario]
}

private struct CorpusScenario: Decodable {
    let id: String
    let palette: [CorpusPaletteColor]
    let target: CorpusTarget
    let weights: CorpusChannels
    let expected: CorpusExpected
}

private struct CorpusPaletteColor: Decodable {
    let index: Int
    let hexColor: String
    let channels: CorpusChannels
}

private struct CorpusTarget: Decodable {
    let channels: CorpusChannels
}

private struct CorpusChannels: Decodable {
    let white: Double?
    let red: Double?
    let green: Double?
    let blue: Double?
    let lps: Double?

    var lightingValues: [LightingCondition: Double] {
        [
            .white: white,
            .red: red,
            .green: green,
            .blue: blue,
            .lps: lps
        ].compactMapValues { $0 }
    }

    var channelWeights: ChannelWeights {
        ChannelWeights(
            white: white ?? 0,
            red: red ?? 0,
            green: green ?? 0,
            blue: blue ?? 0,
            lps: lps ?? 0
        )
    }
}

private struct CorpusExpected: Decodable {
    let error: Double?
    let scores: [CorpusExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct CorpusExpectedScore: Decodable {
    let index: Int
    let score: CorpusScore
}

private enum CorpusScore: Decodable, CustomStringConvertible {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected score or excluded")
        }
    }

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .value(let value): return String(value)
        }
    }
}

private extension ScorerResult {
    var value: Double? {
        guard case .score(let value) = self else { return nil }
        return value
    }
}
