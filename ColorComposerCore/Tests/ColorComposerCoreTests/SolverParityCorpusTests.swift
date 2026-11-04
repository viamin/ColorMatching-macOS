import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedParityCorpus() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let corpus = try decoder.decode(Corpus.self, from: try Data(contentsOf: corpusURL))
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            let target = TargetResponseVector(scenario.target.channels)
            let weights = scenario.weights.channelWeights
            let scored = scenario.palette.map { candidate in
                WeightedSquaredErrorScorer().score(candidate: candidate.paletteColor, target: target, weights: weights)
            }
            let scores = scored.map(ParityScore.init)
            XCTAssertEqual(scores, scenario.expected.scores, scenario.id)

            let minimum = scored.enumerated().compactMap { index, result -> (Int, Double)? in
                guard case .score(let score) = result else { return nil }
                return (index, score)
            }.min { $0.1 < $1.1 }
            XCTAssertEqual(minimum?.0, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(minimum?.1, scenario.expected.error, scenario.id)
            XCTAssertEqual(minimum.map { scenario.palette[$0.0].hex }, scenario.expected.selectedHex, scenario.id)
            XCTAssertEqual(scored.enumerated().compactMap { index, result in
                guard case .score(let score) = result, score == minimum?.1 else { return nil }
                return index
            }, scenario.expected.tiedIndices, scenario.id)
        }
    }

    private var corpusURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let weights: Channels
    let target: Vector
    let palette: [Vector]
    let expected: Expected
}

private struct Vector: Decodable {
    let hex: String?
    let channels: [LightingCondition: Double]

    var paletteColor: PaletteColor {
        let hex = hex!
        return PaletteColor(id: 0, hex: hex, rgb: RGBColor(hex: hex)!, responses: channels.mapValues(IlluminationResponse.init(brightness:)))
    }
}

private struct Channels: Decodable {
    let values: [LightingCondition: Double]

    init(from decoder: Decoder) throws {
        values = try [LightingCondition: Double](from: decoder)
    }

    var channelWeights: ChannelWeights {
        ChannelWeights(white: values[.white] ?? 0, red: values[.red] ?? 0, green: values[.green] ?? 0, blue: values[.blue] ?? 0, lps: values[.lps] ?? 0)
    }
}

private struct Expected: Decodable {
    let scores: [ParityScore]
    let selectedIndex: Int?
    let selectedHex: String?
    let error: Double?
    let tiedIndices: [Int]
}

private enum ParityScore: Decodable, Equatable {
    case excluded
    case score(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) { self = .score(value) }
        else if try container.decode(String.self) == "excluded" { self = .excluded }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected score or excluded") }
    }

    init(_ result: ScorerResult) {
        self = switch result { case .excluded: .excluded; case .score(let value): .score(value) }
    }
}
