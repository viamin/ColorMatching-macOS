import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testWeightedSquaredErrorAndSelectionMatchCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = target(from: scenario.target)
            let weights = weights(from: scenario.weights)
            let palette = scenario.palette.map(color(from:))
            let scores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            assertScores(
                scores,
                match: scenario.expected.scores,
                scenarioID: scenario.id
            )
            assertSelection(
                scores,
                match: scenario.expected,
                palette: palette,
                scenarioID: scenario.id
            )

            if scenario.expected.selectedIndex != nil {
                let result = try CompositionSolver(scorer: scorer).solve(
                    palette: palette,
                    sourceGrids: sourceGrids(from: scenario.target, weights: weights),
                    weights: weights
                )
                XCTAssertEqual(result.colorIndices, [scenario.expected.selectedIndex], scenario.id)
                XCTAssertEqual(result.errors, [scenario.expected.error!], scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func weights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0],
            red: values["red", default: 0],
            green: values["green", default: 0],
            blue: values["blue", default: 0],
            lps: values["lps", default: 0]
        )
    }

    private func target(from vector: ParityVector) -> TargetResponseVector {
        TargetResponseVector(responses(from: vector.channels))
    }

    private func color(from vector: ParityVector) -> PaletteColor {
        PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: responses(from: vector.channels)
        )
    }

    private func responses(
        from channels: [String: Double]
    ) -> [LightingCondition: IlluminationResponse] {
        channels.reduce(into: [:]) { responses, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            responses[condition] = IlluminationResponse(brightness: entry.value)
        }
    }

    private func sourceGrids(
        from target: ParityVector,
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeConditions.compactMap { condition in
            target.channels[condition.rawValue].map { (condition, BrightnessGrid(width: 1, height: 1, values: [$0])) }
        })
    }

    private func assertScores(
        _ actual: [ScorerResult],
        match expected: [ParityScore],
        scenarioID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, scenarioID, file: file, line: line)
        for expectation in expected {
            switch (actual[expectation.index], expectation.value) {
            case (.excluded, .excluded):
                continue
            case (.score(let actual), .score(let expected)):
                XCTAssertEqual(actual, expected, scenarioID, file: file, line: line)
            default:
                XCTFail("\\(scenarioID): candidate \\(expectation.index) score mismatch", file: file, line: line)
            }
        }
    }

    private func assertSelection(
        _ scores: [ScorerResult],
        match expected: ParityExpected,
        palette: [PaletteColor],
        scenarioID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let selectedIndex = scores.enumerated().reduce(nil as Int?) { best, entry in
            guard case .score(let score) = entry.element else { return best }
            guard let best else { return entry.offset }
            guard case .score(let bestScore) = scores[best], score < bestScore else { return best }
            return entry.offset
        }
        XCTAssertEqual(selectedIndex, expected.selectedIndex, scenarioID, file: file, line: line)
        XCTAssertEqual(selectedIndex.map { palette[$0].hex }, expected.selectedHexColor, scenarioID, file: file, line: line)

        guard let selectedIndex, let expectedError = expected.error else {
            XCTAssertNil(expected.error, scenarioID, file: file, line: line)
            XCTAssertNil(expected.tieBroke, scenarioID, file: file, line: line)
            XCTAssertTrue(expected.tiedIndices.isEmpty, scenarioID, file: file, line: line)
            return
        }
        guard case .score(let score) = scores[selectedIndex] else {
            return XCTFail("\\(scenarioID): selected candidate was excluded", file: file, line: line)
        }
        XCTAssertEqual(score, expectedError, scenarioID, file: file, line: line)
        let tiedIndices = scores.indices.filter {
            guard case .score(let score) = scores[$0] else { return false }
            return score == expectedError
        }
        XCTAssertEqual(tiedIndices, expected.tiedIndices, scenarioID, file: file, line: line)
        XCTAssertEqual(tiedIndices.count > 1, expected.tieBroke, scenarioID, file: file, line: line)
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
    let weights: [String: Double]
    let target: ParityVector
    let palette: [ParityVector]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let scores: [ParityScore]
    let selectedIndex: Int?
    let selectedHexColor: String?
    let error: Double?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    enum Value {
        case excluded
        case score(Double)
    }

    let index: Int
    let value: Value

    private enum CodingKeys: String, CodingKey {
        case index
        case score
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        if let score = try? container.decode(Double.self, forKey: .score) {
            value = .score(score)
        } else {
            guard try container.decode(String.self, forKey: .score) == "excluded" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .score,
                    in: container,
                    debugDescription: "Expected a numeric score or excluded"
                )
            }
            value = .excluded
        }
    }
}
