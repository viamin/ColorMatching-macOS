import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedServerParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let weights = makeWeights(scenario.weights)
            let target = makeTarget(scenario.target)
            let palette = try scenario.palette.enumerated().map { index, vector in
                try makePaletteColor(vector, id: index)
            }

            let actualScores = palette.map {
                scoreValue(scorer.score(candidate: $0, target: target, weights: weights))
            }
            XCTAssertEqual(scenario.expected.scores.map(\.index), Array(palette.indices), scenario.id)
            XCTAssertEqual(actualScores, scenario.expected.scores.map(\.score), scenario.id)

            let actualTiedIndices = tiedIndices(in: actualScores)
            XCTAssertEqual(actualTiedIndices, scenario.expected.tiedIndices, scenario.id)
            XCTAssertEqual(actualTiedIndices.count > 1, scenario.expected.tieBroke, scenario.id)

            let selectedIndex = earliestWinningIndex(in: actualScores)
            XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(selectedIndex.map { palette[$0].hex }, scenario.expected.selectedHexColor, scenario.id)
            XCTAssertEqual(selectedIndex.map { actualScores[$0]! }, scenario.expected.error, scenario.id)
        }
    }

    func testSolverSelectionMatchesCorpusWhenEveryRequiredTargetChannelIsPresent() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            let weights = makeWeights(scenario.weights)
            let required = Set(weights.activeConditions)
            let targetChannels = Set(scenario.target.channels.compactMap { LightingCondition(rawValue: $0.key) })
            guard required.isSubset(of: targetChannels) else { continue }

            let palette = try scenario.palette.enumerated().map { index, vector in
                try makePaletteColor(vector, id: index)
            }
            let sourceGrids = sourceGrids(for: scenario.target, required: required)
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: sourceGrids,
                weights: weights
            )

            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
            if let expectedError = scenario.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, scenario.id)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> SolverParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/solver-parity-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SolverParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makeWeights(_ values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func makeTarget(_ vector: SolverParityVector) -> TargetResponseVector {
        TargetResponseVector(responses(for: vector))
    }

    private func makePaletteColor(_ vector: SolverParityVector, id: Int) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: vector.hexColor), "Invalid corpus hex color: \(vector.hexColor)")
        return PaletteColor(
            id: id,
            hex: vector.hexColor,
            rgb: rgb,
            responses: responses(for: vector).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func responses(for vector: SolverParityVector) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: vector.channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func sourceGrids(
        for target: SolverParityVector,
        required: Set<LightingCondition>
    ) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: required.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [target.channels[condition.rawValue]!]))
        })
    }

    private func scoreValue(_ result: ScorerResult) -> Double? {
        guard case .score(let value) = result else { return nil }
        return value
    }

    private func earliestWinningIndex(in scores: [Double?]) -> Int? {
        scores.enumerated().reduce(nil as Int?) { best, candidate in
            guard let score = candidate.element else { return best }
            guard let best else { return candidate.offset }
            return score < scores[best]! ? candidate.offset : best
        }
    }

    private func tiedIndices(in scores: [Double?]) -> [Int] {
        guard let winner = earliestWinningIndex(in: scores), let best = scores[winner] else { return [] }
        return scores.enumerated().compactMap { $0.element == best ? $0.offset : nil }
    }
}

private struct SolverParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
    let scenarios: [SolverParityScenario]
}

private struct SolverParityScenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: SolverParityVector
    let palette: [SolverParityVector]
    let expected: SolverParityExpectation
}

private struct SolverParityVector: Decodable {
    let hexColor: String
    let channels: [String: Double]
}

private struct SolverParityExpectation: Decodable {
    let scores: [SolverParityScore]
    let selectedIndex: Int?
    let selectedHexColor: String?
    let error: Double?
    let tieBroke: Bool
    let tiedIndices: [Int]
}

private struct SolverParityScore: Decodable, Equatable {
    let index: Int
    let score: Double?

    private enum CodingKeys: String, CodingKey {
        case index
        case score
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        index = try values.decode(Int.self, forKey: .index)
        if let score = try? values.decode(Double.self, forKey: .score) {
            self.score = score
        } else {
            guard try values.decode(String.self, forKey: .score) == "excluded" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .score,
                    in: values,
                    debugDescription: "Expected a score number or the excluded marker."
                )
            }
            self.score = nil
        }
    }
}
