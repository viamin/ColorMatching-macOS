import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testCorpusSelectionsMatchExpectedCandidatesExactly() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            let palette = try scenario.palette.map(makePaletteColor)
            let target = try targetResponseVector(for: scenario.target.channels)
            let weights = channelWeights(for: scenario.weights)
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: try sourceGrids(for: scenario.target.channels),
                weights: weights
            )

            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
            if let expectedError = scenario.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, scenario.id)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
            }
            XCTAssertEqual(scores(for: palette, target: target, weights: weights), scenario.expected.scores, scenario.id)
            XCTAssertEqual(tiedIndices(in: palette, target: target, weights: weights), scenario.expected.tiedIndices, scenario.id)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makePaletteColor(_ candidate: ParityVector) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: candidate.hexColor), candidate.hexColor)
        let responses = candidate.channels.reduce(into: [LightingCondition: IlluminationResponse]()) {
            partialResult, entry in
            partialResult[try lightingCondition(for: entry.key)] = IlluminationResponse(brightness: entry.value)
        }
        return PaletteColor(id: candidate.index ?? -1, hex: candidate.hexColor, rgb: rgb, responses: responses)
    }

    private func sourceGrids(for target: [String: Double]) throws -> [LightingCondition: BrightnessGrid] {
        try Dictionary(uniqueKeysWithValues: target.map { key, brightness in
            (try lightingCondition(for: key), BrightnessGrid(width: 1, height: 1, values: [brightness]))
        })
    }

    private func targetResponseVector(for target: [String: Double]) throws -> TargetResponseVector {
        TargetResponseVector(try Dictionary(uniqueKeysWithValues: target.map { key, brightness in
            (try lightingCondition(for: key), brightness)
        }))
    }

    private func scores(
        in palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> [ParityScore] {
        let scorer = WeightedSquaredErrorScorer()
        return palette.enumerated().map { index, candidate in
            switch scorer.score(candidate: candidate, target: target, weights: weights) {
            case .excluded: return ParityScore(index: index, score: .excluded)
            case .score(let score): return ParityScore(index: index, score: .value(score))
            }
        }
    }

    private func tiedIndices(in palette: [PaletteColor], target: TargetResponseVector, weights: ChannelWeights) -> [Int] {
        let scorer = WeightedSquaredErrorScorer()
        let scores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
        guard let best = scores.compactMap({ if case .score(let value) = $0 { value } else { nil } }).min() else { return [] }
        return scores.enumerated().compactMap { index, score in
            if case .score(let value) = score, value == best { return index }
            return nil
        }
    }

    private func channelWeights(for weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white"] ?? 0,
            red: weights["red"] ?? 0,
            green: weights["green"] ?? 0,
            blue: weights["blue"] ?? 0,
            lps: weights["lps"] ?? 0
        )
    }

    private func lightingCondition(for name: String) throws -> LightingCondition {
        try XCTUnwrap(LightingCondition(rawValue: name), "Unknown corpus lighting condition: \(name)")
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
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedIndex: Int?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable, Equatable {
    let index: Int
    let score: Score
}

private enum Score: Decodable, Equatable {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) { self = .value(value) }
        else { self = .excluded }
    }
}
