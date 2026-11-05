import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testReplaysVersionOneColorMatchingParityCorpus() throws {
        let corpus = try JSONDecoder().decode(Corpus.self, from: try Data(contentsOf: corpusURL))
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private var corpusURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-parity-v1.json")
    }

    private func assertScenario(_ scenario: Scenario) throws {
        let weights = weights(from: scenario.weights)
        let target = TargetResponseVector(responses(from: scenario.target))
        let palette = scenario.palette.enumerated().map { index, entry in
            PaletteColor(
                id: index,
                hex: entry.hex,
                rgb: RGBColor(hex: entry.hex)!,
                responses: responses(from: entry.channels).mapValues { IlluminationResponse(brightness: $0) }
            )
        }
        let scorer = WeightedSquaredErrorScorer()
        let scores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        for (index, expected) in scenario.scores.enumerated() {
            switch (scores[index], expected) {
            case (.excluded, nil): break
            case (.score(let actual), .some(let expected)):
                XCTAssertEqual(actual, expected, accuracy: 0, scenario.id)
            default: XCTFail("\(scenario.id): score mismatch at palette index \(index)")
            }
        }

        if weights.activeEntries.contains(where: { target.value(for: $0.condition) == nil }) {
            XCTAssertNil(scenario.selectedIndex, scenario.id)
            XCTAssertTrue(scores.allSatisfy { $0 == .excluded }, scenario.id)
            return
        }

        let grids = Dictionary(uniqueKeysWithValues: weights.activeEntries.map { condition, _ in
            (condition, BrightnessGrid(width: 1, height: 1, values: [target.value(for: condition)!]))
        })
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)
        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.selectedIndex, scenario.id)
        if let expectedError = scenario.error {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 0, scenario.id)
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
        }
        XCTAssertEqual(tiedIndices(scores, error: scenario.error), scenario.ties, scenario.id)
    }

    private func tiedIndices(_ scores: [ScorerResult], error: Double?) -> [Int] {
        guard let error else { return [] }
        return scores.enumerated().compactMap { index, result in
            if case .score(let score) = result, score == error { return index }
            return nil
        }
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in LightingCondition(rawValue: key).map { ($0, value) } })
    }

    private func weights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(white: values["white"] ?? 0, red: values["red"] ?? 0, green: values["green"] ?? 0, blue: values["blue"] ?? 0, lps: values["lps"] ?? 0)
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let selection: String
    let missingPolicy: String
    let scenarios: [Scenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case selection
        case missingPolicy = "missing_policy"
        case scenarios
    }
}

private struct Scenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: [String: Double]
    let palette: [CorpusColor]
    let scores: [Double?]
    let selectedIndex: Int?
    let error: Double?
    let ties: [Int]

    enum CodingKeys: String, CodingKey { case id, weights = "w", target = "t", palette = "p", scores = "s", selectedIndex = "i", error = "e", ties }
}

private struct CorpusColor: Decodable {
    let hex: String
    let channels: [String: Double]

    enum CodingKeys: String, CodingKey { case hex = "h", channels = "c" }
}
