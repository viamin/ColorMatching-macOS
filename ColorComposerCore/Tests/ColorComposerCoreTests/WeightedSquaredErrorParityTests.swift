import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testV1CorpusMatchesWeightedSquaredErrorSelectionsExactly() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            let target = TargetResponseVector(responses(from: scenario.target.channels))
            let palette = scenario.palette.map(makeColor)
            let weights = makeWeights(scenario.weights)
            let scorer = WeightedSquaredErrorScorer()

            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
            XCTAssertEqual(scenario.expected.scores.map(\.index), Array(palette.indices), scenario.id)
            XCTAssertEqual(actualScores, scenario.expected.scores.map(\.score), scenario.id)

            let tiedIndices: [Int]
            if let expectedError = scenario.expected.error {
                tiedIndices = actualScores.enumerated().compactMap { index, score -> Int? in
                    guard case .score(let value) = score, value == expectedError else { return nil }
                    return index
                }
            } else {
                tiedIndices = []
            }
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
            let selectedIndex = tiedIndices.first

            XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(
                selectedIndex.map { palette[$0].hex },
                scenario.expected.selectedHexColor,
                scenario.id
            )
            XCTAssertEqual(
                scenario.expected.tiedIndices.first,
                scenario.expected.selectedIndex,
                scenario.id
            )

            guard scenario.target.hasMeasurements(for: weights.activeConditions) else { continue }
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: grids(from: scenario.target.channels),
                weights: weights
            )

            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
            if let expectedError = scenario.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 0, scenario.id)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> Corpus {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Corpus.self, from: Data(contentsOf: file))
    }

    private func makeColor(_ entry: Corpus.Vector) -> PaletteColor {
        PaletteColor(
            id: entry.index!,
            hex: entry.hexColor,
            rgb: RGBColor(hex: entry.hexColor)!,
            responses: responses(from: entry.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func makeWeights(_ values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0],
            red: values["red", default: 0],
            green: values["green", default: 0],
            blue: values["blue", default: 0],
            lps: values["lps", default: 0]
        )
    }

    private func responses(from values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func grids(from values: [String: Double]) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: responses(from: values).map {
            ($0.key, BrightnessGrid(width: 1, height: 1, values: [$0.value]))
        })
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let scenarios: [Scenario]

    struct Scenario: Decodable {
        let id: String
        let weights: [String: Double]
        let target: Vector
        let palette: [Vector]
        let expected: Expected
    }

    struct Vector: Decodable {
        let index: Int?
        let hexColor: String
        let channels: [String: Double]

        func hasMeasurements(for conditions: [LightingCondition]) -> Bool {
            conditions.allSatisfy { channels[$0.rawValue] != nil }
        }
    }

    struct Expected: Decodable {
        let error: Double?
        let scores: [Score]
        let selectedIndex: Int?
        let selectedHexColor: String?
        let tiedIndices: [Int]
    }

    struct Score: Decodable {
        let index: Int
        let score: ScorerResult

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            index = try container.decode(Int.self, forKey: .index)
            let value = try container.superDecoder(forKey: .score).singleValueContainer()
            if let number = try? value.decode(Double.self) {
                score = .score(number)
            } else {
                guard try value.decode(String.self) == "excluded" else {
                    throw DecodingError.dataCorruptedError(
                        in: value,
                        debugDescription: "Expected a numeric score or excluded."
                    )
                }
                score = .excluded
            }
        }
    }
}

