import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the committed `color_matching` solver corpus.
///
/// The fixture is copied from `viamin/color_matching/priv/parity/v1/corpus.json`.
/// Refresh it with the upstream `mix parity.generate` output whenever its
/// `algorithm_version` changes.
final class SolverParityCorpusTests: XCTestCase {
    func testCorpusMetadataAndCoverage() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })
    }

    func testWeightedSquaredErrorScorerMatchesEveryParityScenario() throws {
        for scenario in try loadCorpus().scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: SolverParityScenario) throws {
        let palette = try palette(for: scenario)
        let target = TargetResponseVector(responses(from: scenario.target.channels))
        let weights = channelWeights(from: scenario.weights)
        let results = palette.map { WeightedSquaredErrorScorer().score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(results.count, scenario.expected.scores.count, scenario.id)
        for (result, expected) in zip(results, scenario.expected.scores.sorted { $0.index < $1.index }) {
            guard palette.indices.contains(expected.index) else {
                return XCTFail("\(scenario.id): corpus candidate index \(expected.index) is out of range")
            }
            XCTAssertEqual(palette[expected.index].id, expected.index, scenario.id)
            switch (result, expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .value(let expected)):
                XCTAssertEqual(actual, expected, scenario.id)
            default:
                XCTFail("\(scenario.id): scorer result differs for candidate \(expected.index)")
            }
        }

        let selection = selectEarliestLowest(results)
        XCTAssertEqual(selection.index, scenario.expected.selectedIndex, scenario.id)
        XCTAssertEqual(selection.error, scenario.expected.error, scenario.id)
        XCTAssertEqual(tiedIndices(results, matching: selection.error), scenario.expected.tiedIndices, scenario.id)
        XCTAssertEqual(selection.error == nil ? nil : tiedIndices(results, matching: selection.error).count > 1, scenario.expected.tieBroke, scenario.id)

        try assertSolverSelectionWhenTargetIsComplete(
            scenario,
            palette: palette,
            weights: weights
        )
    }

    private func assertSolverSelectionWhenTargetIsComplete(
        _ scenario: SolverParityScenario,
        palette: [PaletteColor],
        weights: ChannelWeights
    ) throws {
        let active = weights.activeConditions
        guard active.allSatisfy({ scenario.target.channels[$0.rawValue] != nil }) else { return }

        let grids = Dictionary(uniqueKeysWithValues: active.map {
            ($0, BrightnessGrid(width: 1, height: 1, values: [scenario.target.channels[$0.rawValue]!]))
        })
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
        XCTAssertEqual(result.error(x: 0, y: 0), scenario.expected.error ?? .infinity, scenario.id)
    }

    private func palette(for scenario: SolverParityScenario) throws -> [PaletteColor] {
        try scenario.palette.sorted { $0.index! < $1.index! }.map { vector in
            guard let rgb = RGBColor(hex: vector.hexColor) else {
                throw CorpusError.invalidHex(vector.hexColor)
            }
            return PaletteColor(
                id: try XCTUnwrap(vector.index),
                hex: vector.hexColor,
                rgb: rgb,
                responses: responses(from: vector.channels).mapValues { IlluminationResponse(brightness: $0) }
            )
        }
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func channelWeights(from encoded: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: encoded["white"] ?? 0,
            red: encoded["red"] ?? 0,
            green: encoded["green"] ?? 0,
            blue: encoded["blue"] ?? 0,
            lps: encoded["lps"] ?? 0
        )
    }

    private func selectEarliestLowest(_ results: [ScorerResult]) -> (index: Int?, error: Double?) {
        var selection: (index: Int?, error: Double?) = (nil, nil)
        for (index, result) in results.enumerated() {
            guard case .score(let error) = result else { continue }
            if selection.error == nil || error < selection.error! {
                selection = (index, error)
            }
        }
        return selection
    }

    private func tiedIndices(_ results: [ScorerResult], matching error: Double?) -> [Int] {
        guard let error else { return [] }
        return results.enumerated().compactMap { index, result in
            guard case .score(let candidateError) = result, candidateError == error else { return nil }
            return index
        }
    }

    private func loadCorpus() throws -> SolverParityCorpus {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
        return try JSONDecoder().decode(SolverParityCorpus.self, from: Data(contentsOf: path))
    }
}

private enum CorpusError: Error {
    case invalidHex(String)
}

private struct SolverParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let lightSources: [String]
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
    let index: Int?
    let hexColor: String
    let channels: [String: Double]

    enum CodingKeys: String, CodingKey {
        case index
        case hexColor = "hex_color"
        case channels
    }
}

private struct SolverParityExpected: Decodable {
    let error: Double?
    let scores: [SolverParityScore]
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]

    enum CodingKeys: String, CodingKey {
        case error, scores
        case selectedIndex = "selected_index"
        case tieBroke = "tie_broke"
        case tiedIndices = "tied_indices"
    }
}

private struct SolverParityScore: Decodable {
    let index: Int
    let score: SolverParityScoreValue
}

private enum SolverParityScoreValue: Decodable {
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
