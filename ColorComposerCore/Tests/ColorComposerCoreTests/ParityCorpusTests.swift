import Foundation
import XCTest
@testable import ColorComposerCore

final class ParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            let target = TargetResponseVector(channels: scenario.target)
            let weights = ChannelWeights(channels: scenario.weights)
            let results = scenario.palette.map { color in
                WeightedSquaredErrorScorer().score(
                    candidate: PaletteColor(hex: color.hex, channels: color.channels),
                    target: target,
                    weights: weights
                )
            }

            XCTAssertEqual(results, scenario.expected.results, scenario.id)
            assertSelection(results, expected: scenario.expected, scenario: scenario.id)
        }
    }

    private func assertSelection(_ results: [ScorerResult], expected: Expected, scenario: String) {
        let scores = results.enumerated().compactMap { index, result -> (Int, Double)? in
            guard case .score(let value) = result else { return nil }
            return (index, value)
        }
        let minimum = scores.map(\.1).min()
        let tiedIndices = scores.compactMap { $0.1 == minimum ? $0.0 : nil }
        XCTAssertEqual(tiedIndices, expected.tiedIndices, scenario)
        XCTAssertEqual(tiedIndices.first, expected.selectedIndex, scenario)

        guard let expectedError = expected.error else {
            XCTAssertNil(minimum, scenario)
            return
        }
        XCTAssertNotNil(minimum, scenario)
        XCTAssertEqual(minimum ?? .nan, expectedError, accuracy: 1e-12, scenario)
    }

    private func loadCorpus() throws -> Corpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let selection: String
    let missingPolicy: String
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: [String: Double]
    let palette: [CorpusColor]
    let expected: Expected
}

private struct CorpusColor: Decodable {
    let hex: String
    let channels: [String: Double]
}

private struct Expected: Decodable {
    let error: Double?
    let selectedIndex: Int?
    let tiedIndices: [Int]
    let scores: [Double?]

    var results: [ScorerResult] {
        scores.map { $0.map(ScorerResult.score) ?? .excluded }
    }
}

private extension TargetResponseVector {
    init(channels: [String: Double]) {
        self.init(Dictionary(uniqueKeysWithValues: channels.compactMap { name, value in
            LightingCondition(rawValue: name).map { ($0, value) }
        }))
    }
}

private extension ChannelWeights {
    init(channels: [String: Double]) {
        self.init(
            white: channels["white"] ?? 0,
            red: channels["red"] ?? 0,
            green: channels["green"] ?? 0,
            blue: channels["blue"] ?? 0,
            lps: channels["lps"] ?? 0
        )
    }
}

private extension PaletteColor {
    init(hex: String, channels: [String: Double]) {
        let responses = Dictionary(uniqueKeysWithValues: channels.compactMap { name, value in
            LightingCondition(rawValue: name).map { ($0, IlluminationResponse(brightness: value)) }
        })
        self.init(id: 0, hex: hex, rgb: RGBColor(hex: hex)!, responses: responses)
    }
}
