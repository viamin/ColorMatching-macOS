import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesUpstreamParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            let palette = scenario.palette.map(makePaletteColor)
            let weights = makeWeights(scenario.weights)
            let target = TargetResponseVector(makeChannels(scenario.target.channels))
            let scorer = WeightedSquaredErrorScorer()

            for expectedScore in scenario.expected.scores {
                let actual = scorer.score(
                    candidate: palette[expectedScore.index],
                    target: target,
                    weights: weights
                )
                assertScore(actual, equals: expectedScore.score, scenarioID: scenario.id, index: expectedScore.index)
            }

            let sourceGrids = makeSourceGrids(scenario.target.channels, weights: weights)
            if scenario.expected.selectedIndex == nil,
               sourceGrids.count != weights.activeConditions.count
            {
                XCTAssertThrowsError(
                    try CompositionSolver().solve(palette: palette, sourceGrids: sourceGrids, weights: weights),
                    "Missing target measurements must not be converted into zero-brightness source grids"
                )
                continue
            }

            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: sourceGrids,
                weights: weights
            )

            XCTAssertEqual(
                result.colorIndex(x: 0, y: 0),
                scenario.expected.selectedIndex,
                "Unexpected selected index for corpus scenario \(scenario.id)"
            )
            XCTAssertEqual(
                result.colorIndex(x: 0, y: 0).map { palette[$0].hex },
                scenario.expected.selectedHexColor,
                "Unexpected selected color for corpus scenario \(scenario.id)"
            )

            if let expectedError = scenario.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
            } else {
                XCTAssertEqual(result.error(x: 0, y: 0), .infinity, scenario.id)
            }

            if scenario.expected.tieBroke == true {
                XCTAssertEqual(
                    result.colorIndex(x: 0, y: 0),
                    scenario.expected.tiedIndices.min(),
                    "Ties must select the earliest candidate for corpus scenario \(scenario.id)"
                )
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let url = testFile
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: url))
    }

    private func makePaletteColor(_ fixture: ParityCorpus.PaletteColor) -> PaletteColor {
        PaletteColor(
            id: fixture.index,
            hex: fixture.hexColor,
            rgb: RGBColor(hex: fixture.hexColor)!,
            responses: makeChannels(fixture.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func makeChannels(_ channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
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

    private func makeSourceGrids(
        _ target: [String: Double],
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeConditions.compactMap { condition in
            target[condition.rawValue].map { (condition, BrightnessGrid(width: 1, height: 1, fill: $0)) }
        })
    }

    private func assertScore(
        _ actual: ScorerResult,
        equals expected: ParityCorpus.Score,
        scenarioID: String,
        index: Int
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .value(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "Unexpected score for \(scenarioID) candidate \(index)")
        default:
            XCTFail("Unexpected score state for \(scenarioID) candidate \(index)")
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [Scenario]

    struct Scenario: Decodable {
        let id: String
        let palette: [PaletteColor]
        let target: Vector
        let weights: [String: Double]
        let expected: Expected
    }

    struct PaletteColor: Decodable {
        let channels: [String: Double]
        let hexColor: String
        let index: Int
    }

    struct Vector: Decodable {
        let channels: [String: Double]
    }

    struct Expected: Decodable {
        let error: Double?
        let scores: [CandidateScore]
        let selectedHexColor: String?
        let selectedIndex: Int?
        let tieBroke: Bool?
        let tiedIndices: [Int]
    }

    struct CandidateScore: Decodable {
        let index: Int
        let score: Score
    }

    enum Score: Decodable {
        case excluded
        case value(Double)

        init(from decoder: Decoder) throws {
            if let value = try? decoder.singleValueContainer().decode(Double.self) {
                self = .value(value)
                return
            }
            let value = try decoder.singleValueContainer().decode(String.self)
            guard value == "excluded" else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Unknown corpus score \(value)"
                )
            }
            self = .excluded
        }
    }
}
