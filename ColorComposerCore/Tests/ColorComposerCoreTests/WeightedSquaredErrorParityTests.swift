import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    // Source: viamin/color_matching priv/parity/v1/corpus.json at
    // 47057afd58f7d46b4d4b740ca7d2d08947774471 (issue #111).
    func testMatchesCommittedColorMatchingParityCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let target = TargetResponseVector(channels(from: scenario.target.channels))
        let weights = makeWeights(scenario.weights)
        let palette = try scenario.palette.map(makeColor)
        let scorer = WeightedSquaredErrorScorer()

        for expectedScore in scenario.expected.scores {
            let result = scorer.score(
                candidate: palette[expectedScore.index],
                target: target,
                weights: weights
            )
            assert(result, matches: expectedScore.score, scenario: scenario.id, index: expectedScore.index)
        }

        guard let selectedIndex = scenario.expected.selectedIndex else {
            XCTAssertNil(scenario.expected.error, "\(scenario.id): no selection must have no error")
            XCTAssertTrue(
                scenario.expected.scores.allSatisfy { $0.score == nil },
                "\(scenario.id): every candidate must be excluded"
            )
            return
        }

        XCTAssertEqual(scenario.expected.tiedIndices.first, selectedIndex, "\(scenario.id): ties select the earliest index")
        XCTAssertNotNil(scenario.expected.error, "\(scenario.id): selection must have an error")
        XCTAssertEqual(scenario.expected.tieBroke, scenario.expected.tiedIndices.count > 1, "\(scenario.id): tie evidence")
        XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor, "\(scenario.id): selected color")

        guard let sourceGrids = sourceGrids(for: scenario, weights: scenario.weights) else {
            return XCTFail("\(scenario.id): selected scenario must have every active target channel")
        }
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: sourceGrids,
            weights: weights
        )
        XCTAssertEqual(result.colorIndex(x: 0, y: 0), selectedIndex, "\(scenario.id): selected candidate")
        XCTAssertEqual(result.error(x: 0, y: 0), scenario.expected.error!, accuracy: 1e-12, "\(scenario.id): selected error")
    }

    private func assert(
        _ result: ScorerResult,
        matches expected: Double?,
        scenario: String,
        index: Int
    ) {
        switch (result, expected) {
        case (.excluded, nil):
            break
        case (.score(let actual), .some(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "\(scenario): candidate \(index)")
        default:
            XCTFail("\(scenario): candidate \(index) expected \(String(describing: expected)), got \(result)")
        }
    }

    private func makeColor(_ entry: ParityVector) throws -> PaletteColor {
        guard let rgb = RGBColor(hex: entry.hexColor) else {
            throw ParityCorpusError.invalidHex(entry.hexColor)
        }
        return PaletteColor(
            id: entry.index ?? -1,
            hex: entry.hexColor,
            rgb: rgb,
            responses: channels(from: entry.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
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

    private func channels(from values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func sourceGrids(
        for scenario: ParityScenario,
        weights: [String: Double]
    ) -> [LightingCondition: BrightnessGrid]? {
        let target = channels(from: scenario.target.channels)
        let activeConditions = weights.compactMap { key, weight -> LightingCondition? in
            guard weight > 0 else { return nil }
            return LightingCondition(rawValue: key)
        }
        guard activeConditions.allSatisfy({ target[$0] != nil }) else { return nil }
        return Dictionary(uniqueKeysWithValues: activeConditions.map {
            ($0, BrightnessGrid(width: 1, height: 1, values: [target[$0]!]))
        })
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let selection: String
    let missingPolicy: String
    let scenarios: [ParityScenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case selection
        case missingPolicy = "missing_policy"
        case scenarios
    }
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

    enum CodingKeys: String, CodingKey {
        case index
        case hexColor = "hex_color"
        case channels
    }
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]

    enum CodingKeys: String, CodingKey {
        case error
        case scores
        case selectedHexColor = "selected_hex_color"
        case selectedIndex = "selected_index"
        case tieBroke = "tie_broke"
        case tiedIndices = "tied_indices"
    }
}

private struct ParityScore: Decodable {
    let index: Int
    let score: Double?
}

private enum ParityCorpusError: Error {
    case invalidHex(String)
}
