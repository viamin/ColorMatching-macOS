import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedParityCorpus() throws {
        let corpus = try decodeCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            let target = target(from: scenario.target.channels)
            let weights = weights(from: scenario.weights)
            let candidates = scenario.palette.map(paletteColor(from:))
            let results = candidates.map { candidate in
                WeightedSquaredErrorScorer().score(candidate: candidate, target: target, weights: weights)
            }

            XCTAssertEqual(results.count, scenario.expected.scores.count, scenario.id)
            for expectedScore in scenario.expected.scores {
                let result = results[expectedScore.index]
                switch (result, expectedScore.score) {
                case (.excluded, nil):
                    break
                case (.score(let actual), .some(let expected)):
                    XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario.id)
                default:
                    XCTFail("\(scenario.id): candidate \(expectedScore.index) did not match corpus exclusion")
                }
            }

            assertSelection(
                results,
                candidates: candidates,
                expected: scenario.expected,
                scenarioID: scenario.id
            )
        }
    }

    private func assertSelection(
        _ results: [ScorerResult],
        candidates: [PaletteColor],
        expected: Expected,
        scenarioID: String
    ) {
        var selection: (index: Int, score: Double)?
        for (index, result) in results.enumerated() {
            guard case .score(let score) = result else { continue }
            if selection == nil || score < selection!.score {
                selection = (index, score)
            }
        }

        XCTAssertEqual(selection?.index, expected.selectedIndex, scenarioID)
        XCTAssertEqual(selection.map { candidates[$0.index].hex }, expected.selectedHexColor, scenarioID)
        switch (selection?.score, expected.error) {
        case (.some(let actual), .some(let expectedError)):
            XCTAssertEqual(actual, expectedError, accuracy: 1e-12, scenarioID)
        case (nil, nil):
            break
        default:
            XCTFail("\(scenarioID): selection error did not match corpus")
        }

        let tiedIndices = results.enumerated().compactMap { index, result -> Int? in
            guard case .score(let score) = result, score == selection?.score else { return nil }
            return index
        }
        XCTAssertEqual(tiedIndices, expected.tiedIndices, scenarioID)
        XCTAssertEqual(tiedIndices.count > 1, expected.tieBroke, scenarioID)
    }

    private func decodeCorpus() throws -> Corpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Parity/v1/corpus.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }

    private func target(from channels: [String: Double]) -> TargetResponseVector {
        TargetResponseVector(responseValues(from: channels))
    }

    private func paletteColor(from entry: CorpusEntry) -> PaletteColor {
        PaletteColor(
            id: entry.index ?? -1,
            hex: entry.hexColor,
            rgb: RGBColor(hex: entry.hexColor)!,
            responses: responseValues(from: entry.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func weights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func responseValues(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: CorpusEntry
    let palette: [CorpusEntry]
    let expected: Expected
}

private struct CorpusEntry: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct Expected: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool
    let tiedIndices: [Int]
}

private struct ExpectedScore: Decodable {
    let index: Int
    let score: Double?
}
