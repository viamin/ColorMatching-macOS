import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testCorpusMetadataPinsTheServerSolverContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertFalse(corpus.scenarios.isEmpty)
    }

    func testWeightedSquaredErrorScoresMatchParityCorpusExactly() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let weights = makeWeights(scenario.weights)
            let target = TargetResponseVector(channels(scenario.target.channels))

            for expectedScore in scenario.expected.scores {
                let candidate = try XCTUnwrap(
                    scenario.palette.first(where: { $0.index == expectedScore.index }),
                    "Missing palette entry \(expectedScore.index) in \(scenario.id)"
                )
                let actual = scorer.score(
                    candidate: makePaletteColor(candidate),
                    target: target,
                    weights: weights
                )
                assert(actual, matches: expectedScore.score, scenario: scenario.id, index: candidate.index)
            }
        }
    }

    func testSolverSelectionsMatchParityCorpusIncludingEarliestTieBreaks() throws {
        let corpus = try loadCorpus()
        let solver = CompositionSolver(scorer: WeightedSquaredErrorScorer())

        for scenario in corpus.scenarios where hasAllActiveTargetChannels(scenario) {
            let result = try solver.solve(
                palette: scenario.palette.map(makePaletteColor),
                sourceGrids: sourceGrids(for: scenario),
                weights: makeWeights(scenario.weights)
            )

            XCTAssertEqual(result.colorIndices, [scenario.expected.selectedIndex], scenario.id)
            XCTAssertEqual(result.errors[0], scenario.expected.error ?? .infinity, accuracy: 0, scenario.id)
            XCTAssertEqual(
                result.colorIndices[0].map { scenario.palette[$0].hexColor },
                scenario.expected.selectedHexColor,
                scenario.id
            )
        }
    }

    func testCorpusTieCasesSelectTheirEarliestExpectedMember() throws {
        let corpus = try loadCorpus()
        let solver = CompositionSolver(scorer: WeightedSquaredErrorScorer())
        let tieScenarios = corpus.scenarios.filter { $0.expected.tieBroke == true }

        XCTAssertFalse(tieScenarios.isEmpty)
        for scenario in tieScenarios {
            XCTAssertEqual(scenario.expected.selectedIndex, scenario.expected.tiedIndices.first, scenario.id)
            let result = try solver.solve(
                palette: scenario.palette.map(makePaletteColor),
                sourceGrids: sourceGrids(for: scenario),
                weights: makeWeights(scenario.weights)
            )
            XCTAssertEqual(result.colorIndices[0], scenario.expected.selectedIndex, scenario.id)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testDirectory.appendingPathComponent("Fixtures/solver-parity-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }

    private func assert(_ actual: ScorerResult, matches expected: ExpectedScore, scenario: String, index: Int) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            return
        case (.score(let actualScore), .score(let expectedScore)):
            XCTAssertEqual(actualScore, expectedScore, accuracy: 0, "\(scenario), palette index \(index)")
        default:
            XCTFail("\(scenario), palette index \(index): expected \(expected), got \(actual)")
        }
    }

    private func makePaletteColor(_ entry: ParityPaletteEntry) -> PaletteColor {
        PaletteColor(
            id: entry.index,
            hex: entry.hexColor,
            rgb: RGBColor(hex: entry.hexColor)!,
            responses: channels(entry.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func makeWeights(_ values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values[LightingCondition.white.rawValue] ?? 0,
            red: values[LightingCondition.red.rawValue] ?? 0,
            green: values[LightingCondition.green.rawValue] ?? 0,
            blue: values[LightingCondition.blue.rawValue] ?? 0,
            lps: values[LightingCondition.lps.rawValue] ?? 0
        )
    }

    private func sourceGrids(for scenario: ParityScenario) -> [LightingCondition: BrightnessGrid] {
        channels(scenario.target.channels).mapValues { BrightnessGrid(width: 1, height: 1, values: [$0]) }
    }

    private func hasAllActiveTargetChannels(_ scenario: ParityScenario) -> Bool {
        makeWeights(scenario.weights).activeConditions.allSatisfy { scenario.target.channels[$0.rawValue] != nil }
    }

    private func channels(_ values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [ParityScenario]
    let scorer: String
    let selection: String

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case missingPolicy = "missing_policy"
        case scenarios, scorer, selection
    }
}

private struct ParityScenario: Decodable {
    let expected: ParityExpected
    let id: String
    let palette: [ParityPaletteEntry]
    let target: ParityVector
    let weights: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]

    enum CodingKeys: String, CodingKey {
        case error, scores
        case selectedHexColor = "selected_hex_color"
        case selectedIndex = "selected_index"
        case tieBroke = "tie_broke"
        case tiedIndices = "tied_indices"
    }
}

private struct ParityExpectedScore: Decodable {
    let index: Int
    let score: ExpectedScore
}

private enum ExpectedScore: Decodable, CustomStringConvertible {
    case excluded
    case score(Double)

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .score(let value): return "score(\(value))"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .score(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }
}

private struct ParityPaletteEntry: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int

    enum CodingKeys: String, CodingKey {
        case channels, index
        case hexColor = "hex_color"
    }
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
}
