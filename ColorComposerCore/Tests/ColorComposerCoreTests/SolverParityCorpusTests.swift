import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let weights = channelWeights(from: scenario.weights)
        let target = TargetResponseVector(responses(from: scenario.target.channels))
        let palette = try scenario.palette.map(makePaletteColor)
        let scorer = WeightedSquaredErrorScorer()

        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
        XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
        for (actual, expected) in zip(actualScores, scenario.expected.scores) {
            switch (actual, expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actualScore), .score(let expectedScore)):
                XCTAssertEqual(actualScore, expectedScore, accuracy: 1e-12, scenario.id)
            default:
                XCTFail("\(scenario.id): candidate \(expected.index) exclusion did not match corpus")
            }
        }

        let selectedIndex = earliestLowestScore(in: actualScores)
        XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, scenario.id)
        XCTAssertEqual(selectedIndex.map { palette[$0].hex }, scenario.expected.selectedHexColor, scenario.id)

        if let selectedIndex, let expectedError = scenario.expected.error {
            guard case .score(let actualError) = actualScores[selectedIndex] else {
                return XCTFail("\(scenario.id): selected candidate was excluded")
            }
            XCTAssertEqual(actualError, expectedError, accuracy: 1e-12, scenario.id)
        } else {
            XCTAssertNil(scenario.expected.error, scenario.id)
        }

        let tiedIndices = tiedLowestIndices(in: actualScores)
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
        XCTAssertEqual(scenario.expected.tieBroke, tiedIndices.count > 1 ? true : scenario.expected.error == nil ? nil : false, scenario.id)
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func channelWeights(from channels: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: channels["white", default: 0],
            red: channels["red", default: 0],
            green: channels["green", default: 0],
            blue: channels["blue", default: 0],
            lps: channels["lps", default: 0]
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func makePaletteColor(_ entry: ParityVector) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: entry.hexColor), "Invalid corpus color \(entry.hexColor)")
        return PaletteColor(
            id: entry.index ?? -1,
            hex: entry.hexColor,
            rgb: rgb,
            responses: responses(from: entry.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func earliestLowestScore(in scores: [ScorerResult]) -> Int? {
        var selected: (index: Int, score: Double)?
        for (index, result) in scores.enumerated() {
            guard case .score(let score) = result else { continue }
            if selected == nil || score < selected!.score {
                selected = (index, score)
            }
        }
        return selected?.index
    }

    private func tiedLowestIndices(in scores: [ScorerResult]) -> [Int] {
        guard let lowest = scores.compactMap({ result -> Double? in
            guard case .score(let score) = result else { return nil }
            return score
        }).min() else {
            return []
        }
        return scores.enumerated().compactMap { index, result in
            guard case .score(let score) = result, score == lowest else { return nil }
            return index
        }
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
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedIndex: Int?
    let selectedHexColor: String?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: Score

    enum Score: Decodable {
        case score(Double)
        case excluded

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let score = try? container.decode(Double.self) {
                self = .score(score)
            } else if try container.decode(String.self) == "excluded" {
                self = .excluded
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected score or excluded")
            }
        }
    }
}
