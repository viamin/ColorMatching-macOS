import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testV1CorpusMatchesScoresAndSelections() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertScoresMatch(scenario)
            try assertSolverSelectionMatches(scenario)
        }
    }

    private func assertScoresMatch(_ scenario: ParityScenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let target = TargetResponseVector(knownChannels(in: scenario.target.channels))
        let weights = channelWeights(from: scenario.weights)

        for expected in scenario.expected.scores {
            let candidate = try XCTUnwrap(
                scenario.palette.first(where: { $0.index == expected.index }),
                "Missing candidate \(expected.index) in \(scenario.id)"
            )
            let result = scorer.score(
                candidate: paletteColor(from: candidate),
                target: target,
                weights: weights
            )
            assert(result, matches: expected.score, scenario: scenario, index: expected.index)
        }
    }

    private func assertSolverSelectionMatches(_ scenario: ParityScenario) throws {
        let weights = channelWeights(from: scenario.weights)
        let target = knownChannels(in: scenario.target.channels)
        let palette = scenario.palette.map(paletteColor)

        // A missing target channel cannot be represented by CompositionSolver:
        // source grids are necessarily present for every active channel. Its
        // exclusion behavior is still asserted above through the scorer.
        guard Set(weights.activeConditions).isSubset(of: Set(target.keys)) else {
            XCTAssertNil(scenario.expected.selectedIndex, scenario.id)
            return
        }

        let grids = Dictionary(uniqueKeysWithValues: target.map {
            ($0.key, BrightnessGrid(width: 1, height: 1, values: [$0.value]))
        })
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: grids,
            weights: weights
        )

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
        if let expectedError = scenario.expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
        }
        if let selectedIndex = scenario.expected.selectedIndex {
            XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor, scenario.id)
        }
    }

    private func assert(
        _ actual: ScorerResult,
        matches expected: ParityScore,
        scenario: ParityScenario,
        index: Int
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "\(scenario.id), candidate \(index)")
        default:
            XCTFail("\(scenario.id), candidate \(index): expected \(expected), got \(actual)")
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = directory.appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func paletteColor(from candidate: ParityCandidate) -> PaletteColor {
        PaletteColor(
            id: candidate.index!,
            hex: candidate.hexColor,
            rgb: RGBColor(hex: candidate.hexColor)!,
            responses: knownChannels(in: candidate.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func knownChannels(in channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func channelWeights(from weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights[LightingCondition.white.rawValue, default: 0],
            red: weights[LightingCondition.red.rawValue, default: 0],
            green: weights[LightingCondition.green.rawValue, default: 0],
            blue: weights[LightingCondition.blue.rawValue, default: 0],
            lps: weights[LightingCondition.lps.rawValue, default: 0]
        )
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityCandidate]
    let target: ParityCandidate
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityCandidate: Decodable {
    let index: Int?
    let hexColor: String
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

private enum ParityScore: Decodable, CustomStringConvertible {
    case score(Double)
    case excluded

    var description: String {
        switch self {
        case .score(let value): return String(value)
        case .excluded: return "excluded"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .score(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown parity score")
        }
    }
}
