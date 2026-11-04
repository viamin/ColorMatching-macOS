import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testMatchesCommittedColorMatchingParityCorpus() throws {
        let corpus = try JSONDecoder().decode(
            ParityCorpus.self,
            from: Data(contentsOf: corpusURL())
        )
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            let weights = makeWeights(scenario.weights)
            let target = TargetResponseVector(makeChannels(scenario.target.channels))
            let palette = scenario.palette.map(makeColor)
            let expectedScores = Dictionary(uniqueKeysWithValues: scenario.expected.scores.map { ($0.index, $0.score) })

            for candidate in scenario.palette {
                let result = WeightedSquaredErrorScorer().score(
                    candidate: makeColor(candidate), target: target, weights: weights
                )
                XCTAssertEqual(scoreValue(result), expectedScores[candidate.index!], scenario.id)
            }

            let selected = select(palette: palette, target: target, weights: weights)
            XCTAssertEqual(selected?.0, scenario.expected.selectedIndex, scenario.id)
            assertEqual(selected?.1, scenario.expected.error, scenario.id)

            if scenario.target.hasEveryPositiveWeightChannel(in: scenario.weights) {
                let grids = Dictionary(uniqueKeysWithValues: scenario.weights.compactMap { name, weight in
                    guard weight > 0, let condition = LightingCondition(rawValue: name),
                          let value = scenario.target.channels[name] else { return nil }
                    return (condition, BrightnessGrid(width: 1, height: 1, values: [value]))
                })
                let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)
                XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
                if let expectedError = scenario.expected.error {
                    XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
                }
            }
        }
    }

    private func corpusURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
    }

    private func makeChannels(_ channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, value in
            LightingCondition(rawValue: name).map { ($0, value) }
        })
    }

    private func makeWeights(_ values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0], red: values["red", default: 0],
            green: values["green", default: 0], blue: values["blue", default: 0], lps: values["lps", default: 0]
        )
    }

    private func makeColor(_ vector: ParityVector) -> PaletteColor {
        PaletteColor(
            id: vector.index!, hex: vector.hexColor, rgb: RGBColor(hex: vector.hexColor)!,
            responses: makeChannels(vector.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func scoreValue(_ result: ScorerResult) -> ParityScore {
        switch result {
        case .excluded: return .excluded
        case .score(let value): return .value(value)
        }
    }

    private func assertEqual(_ actual: Double?, _ expected: Double?, _ scenarioID: String) {
        switch (actual, expected) {
        case let (actual?, expected?): XCTAssertEqual(actual, expected, accuracy: 1e-12, scenarioID)
        case (nil, nil): break
        default: XCTFail("Selection mismatch for \(scenarioID): \(String(describing: actual)) != \(String(describing: expected))")
        }
    }

    private func select(palette: [PaletteColor], target: TargetResponseVector, weights: ChannelWeights) -> (Int, Double)? {
        palette.enumerated().reduce(nil) { best, candidate in
            guard case .score(let score) = WeightedSquaredErrorScorer().score(candidate: candidate.element, target: target, weights: weights) else { return best }
            guard let best else { return (candidate.offset, score) }
            return score < best.1 ? (candidate.offset, score) : best
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scenarios: [ParityScenario]
    let selection: String
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedIndex: Int?
}

private struct ParityExpectedScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable, Equatable {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) { self = .value(value) }
        else { self = .excluded }
    }
}

private extension ParityVector {
    func hasEveryPositiveWeightChannel(in weights: [String: Double]) -> Bool {
        weights.allSatisfy { name, weight in
            weight <= 0 || LightingCondition(rawValue: name) == nil || channels[name] != nil
        }
    }
}
