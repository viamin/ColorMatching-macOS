import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testMatchesCommittedColorMatchingParityCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let palette = try scenario.palette.map(makeColor)
        let target = TargetResponseVector(knownChannels(in: scenario.target.channels))
        let weights = makeWeights(from: scenario.weights)
        let scorer = WeightedSquaredErrorScorer()

        XCTAssertEqual(scenario.palette.map(\.index), Array(palette.indices), "\(scenario.id) corpus indices must be palette order")
        for expectedScore in scenario.expected.scores {
            let result = scorer.score(
                candidate: palette[expectedScore.index],
                target: target,
                weights: weights
            )
            assert(result, equals: expectedScore.score, scenarioID: scenario.id, index: expectedScore.index)
        }

        let activeTargetIsComplete = weights.activeConditions.allSatisfy { target.value(for: $0) != nil }
        if activeTargetIsComplete {
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: sourceGrids(from: target, weights: weights),
                weights: weights
            )
            let selectedIndex = result.colorIndex(x: 0, y: 0)
            XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(
                selectedIndex.map { palette[$0].hex },
                scenario.expected.selectedHexColor,
                scenario.id
            )
            assert(result.error(x: 0, y: 0), equals: scenario.expected.error, scenarioID: scenario.id)
        } else {
            XCTAssertNil(scenario.expected.selectedIndex, "\(scenario.id) has an incomplete target")
            XCTAssertTrue(
                scenario.expected.scores.allSatisfy { $0.score == .excluded },
                "\(scenario.id) must exclude every candidate"
            )
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makeColor(_ entry: ParityPaletteEntry) throws -> PaletteColor {
        PaletteColor(
            id: entry.index,
            hex: entry.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: entry.hexColor)),
            responses: knownChannels(in: entry.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func sourceGrids(
        from target: TargetResponseVector,
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [target.value(for: condition)!]))
        })
    }

    private func knownChannels(in channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, value in
            LightingCondition(rawValue: name).map { ($0, value) }
        })
    }

    private func makeWeights(from weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights[LightingCondition.white.rawValue] ?? 0,
            red: weights[LightingCondition.red.rawValue] ?? 0,
            green: weights[LightingCondition.green.rawValue] ?? 0,
            blue: weights[LightingCondition.blue.rawValue] ?? 0,
            lps: weights[LightingCondition.lps.rawValue] ?? 0
        )
    }

    private func assert(
        _ actual: ScorerResult,
        equals expected: ParityScore,
        scenarioID: String,
        index: Int
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .value(let expected)):
            XCTAssertEqual(actual, expected, "\(scenarioID), palette index \(index)")
        default:
            XCTFail("\(scenarioID), palette index \(index): expected \(expected), got \(actual)")
        }
    }

    private func assert(_ actual: Double, equals expected: Double?, scenarioID: String) {
        guard let expected else {
            XCTAssertTrue(actual.isInfinite, scenarioID)
            return
        }
        XCTAssertEqual(actual, expected, scenarioID)
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
    let palette: [ParityPaletteEntry]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityPaletteEntry: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
}

private struct ParityExpectedScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable, Equatable, CustomStringConvertible {
    case excluded
    case value(Double)

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .value(let value): return String(value)
        }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let number = try? value.decode(Double.self) {
            self = .value(number)
        } else if try value.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Expected score or excluded")
        }
    }
}
