import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testReplaysCommittedColorMatchingParityCorpusExactly() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: ParityScenario) throws {
        let palette = try scenario.palette
            .sorted { ($0.index ?? .max) < ($1.index ?? .max) }
            .map(makeColor)
        let target = TargetResponseVector(knownChannels(in: scenario.target.channels))
        let weights = makeWeights(scenario.weights)
        let results = palette.map {
            WeightedSquaredErrorScorer().score(candidate: $0, target: target, weights: weights)
        }
        let expectedScores = scenario.expected.scores.sorted { $0.index < $1.index }

        XCTAssertEqual(results.count, expectedScores.count, scenario.id)
        for (result, expected) in zip(results, expectedScores) {
            assert(result, equals: expected.score, scenarioID: scenario.id)
        }

        let selection = earliestSelection(from: results)
        XCTAssertEqual(selection?.index, scenario.expected.selectedIndex, scenario.id)
        XCTAssertEqual(selection.map { palette[$0.index].hex }, scenario.expected.selectedHexColor, scenario.id)
        XCTAssertEqual(selection?.score, scenario.expected.error, scenario.id)

        let tiedIndices = results.enumerated().compactMap { index, result -> Int? in
            guard case .score(let score) = result, score == scenario.expected.error else { return nil }
            return index
        }
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
        XCTAssertEqual(scenario.expected.tieBroke, tiedIndices.count > 1 ? true : selection == nil ? nil : false, scenario.id)

        guard scenario.expected.selectedIndex != nil,
              scenario.targetHasEveryActiveChannel(weights: scenario.weights)
        else { return }

        let grids = try sourceGrids(from: scenario.target.channels, weights: weights)
        let solved = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)
        XCTAssertEqual(solved.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
        XCTAssertEqual(solved.error(x: 0, y: 0), scenario.expected.error, scenario.id)
    }

    private func assert(_ result: ScorerResult, equals expected: ParityScore, scenarioID: String) {
        switch (result, expected) {
        case (.excluded, .excluded):
            return
        case (.score(let actual), .value(let expected)):
            XCTAssertEqual(actual, expected, scenarioID)
        default:
            XCTFail("\(scenarioID): scorer result did not match corpus")
        }
    }

    private func earliestSelection(from results: [ScorerResult]) -> (index: Int, score: Double)? {
        var selected: (index: Int, score: Double)?
        for (index, result) in results.enumerated() {
            guard case .score(let score) = result else { continue }
            if selected == nil || score < selected!.score {
                selected = (index, score)
            }
        }
        return selected
    }

    private func sourceGrids(
        from channels: [String: Double], weights: ChannelWeights
    ) throws -> [LightingCondition: BrightnessGrid] {
        try Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            let value = try XCTUnwrap(channels[condition.rawValue], "Missing active target channel \(condition)")
            return (condition, BrightnessGrid(width: 1, height: 1, values: [value]))
        })
    }

    private func makeColor(_ vector: ParityVector) throws -> PaletteColor {
        let hex = try XCTUnwrap(RGBColor(hex: vector.hexColor), "Invalid corpus hex \(vector.hexColor)")
        return PaletteColor(
            id: try XCTUnwrap(vector.index, "Palette vector lacks an index"),
            hex: vector.hexColor,
            rgb: hex,
            responses: knownChannels(in: vector.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func knownChannels(in channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: LightingCondition.all.compactMap { condition in
            channels[condition.rawValue].map { (condition, $0) }
        })
    }

    private func makeWeights(_ weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white"] ?? 0,
            red: weights["red"] ?? 0,
            green: weights["green"] ?? 0,
            blue: weights["blue"] ?? 0,
            lps: weights["lps"] ?? 0
        )
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/color-matching-parity-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpected

    func targetHasEveryActiveChannel(weights: [String: Double]) -> Bool {
        weights.allSatisfy { source, weight in
            weight <= 0 || LightingCondition(rawValue: source) == nil || target.channels[source] != nil
        }
    }
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
    let score: ParityScore
}

private enum ParityScore: Decodable {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let score = try? value.decode(Double.self) {
            self = .value(score)
        } else {
            XCTAssertEqual(try value.decode(String.self), "excluded")
            self = .excluded
        }
    }
}
