import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testMatchesCommittedV1ParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)

        for scenario in corpus.scenarios {
            let target = TargetResponseVector(responses(from: scenario.target.channels))
            let weights = weights(from: scenario.weights)
            let palette = scenario.palette.map(paletteColor(from:))
            let scores = palette.map { score(for: $0, target: target, weights: weights) }

            XCTAssertEqual(scenario.expected.scores.map(\.index), scenario.palette.map { $0.index! }, scenario.id)
            XCTAssertEqual(scores, scenario.expected.scores.map(\.score), scenario.id)
            XCTAssertEqual(selectedIndex(from: scores), scenario.expected.selectedIndex, scenario.id)
            try assertSolverSelection(
                scenario,
                targetResponses: responses(from: scenario.target.channels),
                weights: weights
            )

            if let selectedIndex = scenario.expected.selectedIndex {
                XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor, scenario.id)
                XCTAssertEqual(scores[selectedIndex], .score(scenario.expected.error!), scenario.id)
            } else {
                XCTAssertTrue(scores.allSatisfy { $0 == .excluded }, scenario.id)
            }

            if scenario.expected.tieBroke == true {
                XCTAssertEqual(scenario.expected.tiedIndices.first, scenario.expected.selectedIndex, scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func weights(from channels: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: channels["white"] ?? 0,
            red: channels["red"] ?? 0,
            green: channels["green"] ?? 0,
            blue: channels["blue"] ?? 0,
            lps: channels["lps"] ?? 0
        )
    }

    private func paletteColor(from vector: ParityVector) -> PaletteColor {
        PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: responses(from: vector.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func assertSolverSelection(
        _ scenario: ParityScenario,
        targetResponses: [LightingCondition: Double],
        weights: ChannelWeights
    ) throws {
        guard weights.activeConditions.allSatisfy({ targetResponses[$0] != nil }) else { return }

        let sourceGrids = Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [targetResponses[condition]!]))
        })
        let result = try CompositionSolver().solve(
            palette: scenario.palette.map(paletteColor(from:)),
            sourceGrids: sourceGrids,
            weights: weights
        )

        XCTAssertEqual(result.colorIndices, [scenario.expected.selectedIndex], scenario.id)
        XCTAssertEqual(result.errors, [scenario.expected.error ?? .infinity], scenario.id)
    }

    private func score(
        for candidate: PaletteColor,
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> ExpectedScore {
        switch WeightedSquaredErrorScorer().score(candidate: candidate, target: target, weights: weights) {
        case .excluded:
            return .excluded
        case .score(let value):
            return .score(value)
        }
    }

    private func selectedIndex(from scores: [ExpectedScore]) -> Int? {
        scores.enumerated().reduce(into: nil as Int?) { bestIndex, score in
            guard case .score(let value) = score.element else { return }
            guard let current = bestIndex else {
                bestIndex = score.offset
                return
            }
            guard case .score(let currentValue) = scores[current], value < currentValue else { return }
            bestIndex = score.offset
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityExpectedScore: Decodable {
    let index: Int
    let score: ExpectedScore
}

private enum ExpectedScore: Decodable, Equatable {
    case excluded
    case score(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .score(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }
}
