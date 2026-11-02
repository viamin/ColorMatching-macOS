import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the deterministic golden vectors published by `color_matching`.
///
/// Refresh `Fixtures/weighted_squared_error_v1.json` from
/// `viamin/color_matching`'s `priv/parity/v1/corpus.json` when its algorithm
/// version changes. The fixture exercises weighting, exclusions, and
/// earliest-candidate tie selection together rather than as isolated examples.
final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testCorpusMetadataDescribesTheSharedSolverContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })
    }

    func testWeightedSquaredErrorScorerReplaysEveryCorpusScenarioExactly() throws {
        let scorer = WeightedSquaredErrorScorer()

        for scenario in try loadCorpus().scenarios {
            let target = target(from: scenario.target)
            let weights = weights(from: scenario.weights)
            let palette = scenario.palette.map(color(from:))
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            assertScores(actualScores, match: scenario.expected.scores, scenario: scenario.id)
            assertSelection(actualScores, scenario: scenario)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func color(from vector: ParityVector) -> PaletteColor {
        PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: responses(from: vector.channels)
        )
    }

    private func target(from vector: ParityVector) -> TargetResponseVector {
        TargetResponseVector(brightness(from: vector.channels))
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            condition(named: name).map { ($0, IlluminationResponse(brightness: brightness)) }
        })
    }

    private func brightness(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            condition(named: name).map { ($0, brightness) }
        })
    }

    private func weights(from encoded: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: encoded["white"] ?? 0,
            red: encoded["red"] ?? 0,
            green: encoded["green"] ?? 0,
            blue: encoded["blue"] ?? 0,
            lps: encoded["lps"] ?? 0
        )
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

    private func assertScores(
        _ actual: [ScorerResult],
        match expected: [ParityExpectedScore],
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, "\(scenario): score count", file: file, line: line)
        for (index, expectedScore) in expected.enumerated() {
            XCTAssertEqual(expectedScore.index, index, "\(scenario): corpus score order", file: file, line: line)
            switch (actual[index], expectedScore.score) {
            case (.excluded, .excluded):
                continue
            case (.score(let actualScore), .value(let expectedValue)):
                XCTAssertEqual(actualScore, expectedValue, "\(scenario): candidate \(index)", file: file, line: line)
            default:
                XCTFail("\(scenario): candidate \(index) exclusion disagrees", file: file, line: line)
            }
        }
    }

    private func assertSelection(_ scores: [ScorerResult], scenario: ParityScenario) {
        let ranked = scores.enumerated().compactMap { index, result -> (Int, Double)? in
            guard case .score(let score) = result else { return nil }
            return (index, score)
        }
        let best = ranked.min { $0.1 < $1.1 }
        let expected = scenario.expected

        XCTAssertEqual(best?.0, expected.selectedIndex, "\(scenario.id): selected index")
        XCTAssertEqual(best?.1, expected.error, "\(scenario.id): selected error")
        let tiedIndices = ranked.filter { $0.1 == best?.1 }.map(\.0)
        XCTAssertEqual(tiedIndices, expected.tiedIndices, "\(scenario.id): tied indices")
        XCTAssertEqual(expected.tieBroke, tiedIndices.count > 1 ? true : (best == nil ? nil : false), "\(scenario.id): tie evidence")
        if let selectedIndex = expected.selectedIndex {
            XCTAssertEqual(scenario.palette[selectedIndex].hexColor, expected.selectedHexColor, "\(scenario.id): selected color")
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scenarios: [ParityScenario]
    let scorer: String
    let selection: String
}

private struct ParityScenario: Decodable {
    let expected: ParityExpected
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
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
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown parity score")
        }
    }
}
