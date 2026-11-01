import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testV1CorpusMatchesScoresSelectionsAndTieEvidence() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let weights = ChannelWeights(channels: scenario.weights)
            let target = TargetResponseVector(channels: scenario.target.channels)
            let palette = try scenario.palette.map(makeColor)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
            let expectedScores = scenario.expected.scores.map(\.score)

            XCTAssertEqual(scenario.expected.scores.map(\.index), Array(palette.indices), scenario.id)
            XCTAssertEqual(actualScores, expectedScores, scenario.id)

            let selectedIndex = earliestBestIndex(in: actualScores)
            XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(
                selectedIndex.map { palette[$0].hex },
                scenario.expected.selectedHexColor,
                scenario.id
            )
            XCTAssertEqual(selectedIndex.flatMap { scoreValue(actualScores[$0]) }, scenario.expected.error, scenario.id)

            let tiedIndices = tiedIndices(in: actualScores, selectedIndex: selectedIndex)
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
            let tieBroke = selectedIndex.map { _ in tiedIndices.count > 1 }
            XCTAssertEqual(tieBroke, scenario.expected.tieBroke, scenario.id)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let corpusURL = testFile
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: corpusURL))
    }

    private func makeColor(_ entry: ParityVector) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: entry.hexColor), "Invalid corpus color \(entry.hexColor)")
        let responses = entry.channels.reduce(into: [LightingCondition: IlluminationResponse]()) { result, item in
            if let condition = LightingCondition(rawValue: item.key) {
                result[condition] = IlluminationResponse(brightness: item.value)
            }
        }
        return PaletteColor(id: entry.index ?? -1, hex: entry.hexColor, rgb: rgb, responses: responses)
    }

    private func earliestBestIndex(in scores: [ScorerResult]) -> Int? {
        scores.enumerated().reduce(into: (index: Int?, score: Double.infinity)) { best, item in
            guard case .score(let score) = item.element, score < best.score else { return }
            best = (item.offset, score)
        }.index
    }

    private func tiedIndices(in scores: [ScorerResult], selectedIndex: Int?) -> [Int] {
        guard let selectedIndex, let selectedScore = scoreValue(scores[selectedIndex]) else { return [] }
        return scores.enumerated().compactMap { index, result in
            scoreValue(result) == selectedScore ? index : nil
        }
    }

    private func scoreValue(_ result: ScorerResult) -> Double? {
        guard case .score(let score) = result else { return nil }
        return score
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
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
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ScorerResult

    private enum CodingKeys: String, CodingKey { case index, score }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        if let value = try? container.decode(Double.self, forKey: .score) {
            score = .score(value)
        } else {
            guard try container.decode(String.self, forKey: .score) == "excluded" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .score,
                    in: container,
                    debugDescription: "Expected a numeric score or excluded"
                )
            }
            score = .excluded
        }
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

private extension TargetResponseVector {
    init(channels: [String: Double]) {
        self.init(channels.reduce(into: [LightingCondition: Double]()) { result, item in
            if let condition = LightingCondition(rawValue: item.key) {
                result[condition] = item.value
            }
        })
    }
}
