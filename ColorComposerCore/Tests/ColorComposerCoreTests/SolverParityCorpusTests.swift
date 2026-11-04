import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testCommittedV1CorpusMatchesScorerAndSolverExactly() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: SolverParityScenario) throws {
        let palette = try scenario.palette
            .sorted { ($0.index ?? -1) < ($1.index ?? -1) }
            .map(makePaletteColor)
        let target = makeTarget(from: scenario.target.channels)
        let weights = makeWeights(from: scenario.weights)
        let expected = scenario.expected
        let scorer = WeightedSquaredErrorScorer()

        XCTAssertEqual(
            palette.map { score($0, against: target, weights: weights) },
            expected.scores.sorted { $0.index < $1.index }.map(\.score),
            "\(scenario.id): scorer results differ"
        )

        let result = try CompositionSolver(scorer: scorer).solve(
            palette: palette,
            sourceGrids: makeSourceGrids(from: scenario.target.channels, weights: weights),
            weights: weights
        )

        XCTAssertEqual(result.colorIndices, [expected.selectedIndex], "\(scenario.id): selected palette index differs")
        XCTAssertEqual(result.errors, [expected.error ?? .infinity], "\(scenario.id): selected error differs")
        if expected.selectedIndex == nil {
            XCTAssertTrue(expected.tiedIndices.isEmpty, "\(scenario.id): unmatched scenario must not contain ties")
            XCTAssertNil(expected.tieBroke, "\(scenario.id): unmatched scenario must not claim a tie break")
        } else {
            XCTAssertEqual(
                expected.tiedIndices.first,
                expected.selectedIndex,
                "\(scenario.id): upstream tie evidence must identify the selected earliest index"
            )
            XCTAssertEqual(
                expected.tieBroke,
                expected.tiedIndices.count > 1,
                "\(scenario.id): upstream tie evidence is inconsistent"
            )
        }
    }

    private func score(
        _ color: PaletteColor,
        against target: TargetResponseVector,
        weights: ChannelWeights
    ) -> SolverParityScore {
        switch WeightedSquaredErrorScorer().score(candidate: color, target: target, weights: weights) {
        case .score(let value):
            return .value(value)
        case .excluded:
            return .excluded
        }
    }

    private func makePaletteColor(_ vector: SolverParityVector) throws -> PaletteColor {
        let responses = responses(from: vector.channels)
        guard let rgb = RGBColor(hex: vector.hexColor) else {
            throw SolverParityFixtureError.invalidHex(vector.hexColor)
        }
        return PaletteColor(id: vector.index ?? -1, hex: vector.hexColor, rgb: rgb, responses: responses)
    }

    private func makeTarget(from channels: [String: Double]) -> TargetResponseVector {
        TargetResponseVector(Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            condition(named: name).map { ($0, brightness) }
        }))
    }

    private func makeSourceGrids(
        from channels: [String: Double],
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeConditions.compactMap { condition in
            channels[condition.rawValue].map { (condition, BrightnessGrid(width: 1, height: 1, fill: $0)) }
        })
    }

    private func makeWeights(from channels: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: channels["white", default: 0],
            red: channels["red", default: 0],
            green: channels["green", default: 0],
            blue: channels["blue", default: 0],
            lps: channels["lps", default: 0]
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            condition(named: name).map { ($0, IlluminationResponse(brightness: brightness)) }
        })
    }

    private func condition(named name: String) -> LightingCondition? {
        switch name {
        case "white": return .white
        case "red": return .red
        case "green": return .green
        case "blue": return .blue
        case "lps": return .lps
        default: return nil
        }
    }

    private func loadCorpus() throws -> SolverParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
        return try JSONDecoder().decode(SolverParityCorpus.self, from: Data(contentsOf: fixture))
    }
}

private struct SolverParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let scenarios: [SolverParityScenario]
}

private struct SolverParityScenario: Decodable {
    let id: String
    let palette: [SolverParityVector]
    let target: SolverParityVector
    let weights: [String: Double]
    let expected: SolverParityExpected
}

private struct SolverParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct SolverParityExpected: Decodable {
    let error: Double?
    let scores: [SolverParityCandidateScore]
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct SolverParityCandidateScore: Decodable {
    let index: Int
    let score: SolverParityScore
}

private enum SolverParityScore: Decodable, Equatable {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }
}

private enum SolverParityFixtureError: Error {
    case invalidHex(String)
}
