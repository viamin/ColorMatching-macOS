import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testReplaysUpstreamV1CorpusExactly() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = TargetResponseVector(responseVector(from: scenario.target.channels))
            let weights = channelWeights(from: scenario.weights)
            let palette = scenario.palette.map(makePaletteColor)
            let outcomes = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(outcomes.count, scenario.expected.scores.count, scenario.id)
            for (actual, expected) in zip(outcomes, scenario.expected.scores) {
                XCTAssertEqual(expected.index, scenario.palette[expected.index].index, scenario.id)
                assert(actual, matches: expected.score, scenarioID: scenario.id)
            }

            let selection = selectEarliestMinimum(from: outcomes)
            XCTAssertEqual(selection.index, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(selection.error, scenario.expected.error, scenario.id)
            XCTAssertEqual(
                selection.tiedIndices,
                scenario.expected.tiedIndices,
                "\\(scenario.id): tie candidates must retain upstream order"
            )
            XCTAssertEqual(
                selection.tiedIndices.count > 1,
                scenario.expected.tieBroke ?? false,
                scenario.id
            )

            if let selectedIndex = selection.index {
                XCTAssertEqual(
                    palette[selectedIndex].hex,
                    scenario.expected.selectedHexColor,
                    "\\(scenario.id): selected color"
                )
            } else {
                XCTAssertNil(scenario.expected.selectedHexColor, scenario.id)
                XCTAssertNil(scenario.expected.tieBroke, scenario.id)
            }
        }
    }

    /// The generated client requires the OpenAPI runtime package. This stays
    /// red until the generated-client migration adds the package dependency.
    func testOpenAPIRuntimeIsAvailableToTheClientTarget() {
        #if canImport(OpenAPIRuntime)
        XCTAssertTrue(true)
        #else
        XCTFail("Add swift-openapi-runtime before migrating PaletteAPIClient to the generated client.")
        #endif
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func responseVector(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, brightness) }
        })
    }

    private func channelWeights(from weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white"] ?? 0,
            red: weights["red"] ?? 0,
            green: weights["green"] ?? 0,
            blue: weights["blue"] ?? 0,
            lps: weights["lps"] ?? 0
        )
    }

    private func makePaletteColor(_ vector: ParityVector) -> PaletteColor {
        PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: responseVector(from: vector.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func assert(
        _ actual: ScorerResult,
        matches expected: ExpectedScore,
        scenarioID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, scenarioID, file: file, line: line)
        default:
            XCTFail("\\(scenarioID): expected \\(expected), received \\(actual)", file: file, line: line)
        }
    }

    private func selectEarliestMinimum(from outcomes: [ScorerResult]) -> (index: Int?, error: Double?, tiedIndices: [Int]) {
        var bestIndex: Int?
        var bestError: Double?
        var tiedIndices: [Int] = []

        for (index, outcome) in outcomes.enumerated() {
            guard case .score(let error) = outcome else { continue }
            if bestError == nil || error < bestError! {
                bestIndex = index
                bestError = error
                tiedIndices = [index]
            } else if error == bestError {
                tiedIndices.append(index)
            }
        }
        return (bestIndex, bestError, tiedIndices)
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let selection: String
    let missingPolicy: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: ParityVector
    let palette: [ParityVector]
    let expected: ParityExpectation
}

private struct ParityVector: Decodable {
    let hexColor: String
    let index: Int?
    let channels: [String: Double]
}

private struct ParityExpectation: Decodable {
    let error: Double?
    let scores: [ParityCandidateScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityCandidateScore: Decodable {
    let index: Int
    let score: ExpectedScore
}

private enum ExpectedScore: Decodable {
    case excluded
    case score(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .score(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded marker.")
        }
    }
}
