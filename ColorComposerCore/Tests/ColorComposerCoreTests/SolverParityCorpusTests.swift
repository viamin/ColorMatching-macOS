import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the server-owned golden vectors so solver semantics cannot drift.
final class SolverParityCorpusTests: XCTestCase {
    func testCorpusMetadataDescribesTheSupportedSolverContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
    }

    func testWeightedSquaredErrorScorerExactlyReplaysCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        XCTAssertFalse(corpus.scenarios.isEmpty)
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })

        for scenario in corpus.scenarios {
            let target = try makeTarget(scenario.target)
            let palette = try scenario.palette.map(makeColor)
            let weights = makeWeights(scenario.weights)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            assertScores(
                actualScores,
                match: scenario.expected.scores,
                scenarioID: scenario.id
            )
            assertSelection(
                actualScores,
                palette: palette,
                expected: scenario.expected,
                scenarioID: scenario.id
            )
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixtureURL = testDirectory.appendingPathComponent("Fixtures/Parity/v1/corpus.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makeColor(_ vector: ParityVector) throws -> PaletteColor {
        let responses = try decodeChannels(vector.channels).mapValues(IlluminationResponse.init(brightness:))
        guard let rgb = RGBColor(hex: vector.hexColor) else {
            throw CorpusFixtureError.invalidHexColor(vector.hexColor)
        }
        return PaletteColor(id: vector.index ?? 0, hex: vector.hexColor, rgb: rgb, responses: responses)
    }

    private func makeTarget(_ vector: ParityVector) throws -> TargetResponseVector {
        TargetResponseVector(try decodeChannels(vector.channels))
    }

    private func makeWeights(_ encoded: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: encoded[LightingCondition.white.rawValue, default: 0],
            red: encoded[LightingCondition.red.rawValue, default: 0],
            green: encoded[LightingCondition.green.rawValue, default: 0],
            blue: encoded[LightingCondition.blue.rawValue, default: 0],
            lps: encoded[LightingCondition.lps.rawValue, default: 0]
        )
    }

    private func decodeChannels(_ encoded: [String: Double]) throws -> [LightingCondition: Double] {
        try Dictionary(uniqueKeysWithValues: encoded.map { key, value in
            guard let condition = LightingCondition(rawValue: key) else {
                throw CorpusFixtureError.unknownLightingCondition(key)
            }
            return (condition, value)
        })
    }

    private func assertScores(
        _ actual: [ScorerResult],
        match expected: [ParityExpectedScore],
        scenarioID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, "\(scenarioID): score count", file: file, line: line)

        for expectedScore in expected.sorted(by: { $0.index < $1.index }) {
            guard actual.indices.contains(expectedScore.index) else {
                return XCTFail("\(scenarioID): missing candidate \(expectedScore.index)", file: file, line: line)
            }
            XCTAssertEqual(actual[expectedScore.index], expectedScore.score, "\(scenarioID): candidate \(expectedScore.index)", file: file, line: line)
        }
    }

    private func assertSelection(
        _ scores: [ScorerResult],
        palette: [PaletteColor],
        expected: ParityExpected,
        scenarioID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let ranked = scores.enumerated().compactMap { index, result -> (Int, Double)? in
            guard case .score(let value) = result else { return nil }
            return (index, value)
        }
        let bestError = ranked.map(\.1).min()
        let tiedIndices = ranked.compactMap { $0.1 == bestError ? $0.0 : nil }
        let selectedIndex = tiedIndices.first

        XCTAssertEqual(selectedIndex, expected.selectedIndex, "\(scenarioID): selected index", file: file, line: line)
        XCTAssertEqual(bestError, expected.error, "\(scenarioID): selected error", file: file, line: line)
        XCTAssertEqual(tiedIndices, expected.tiedIndices, "\(scenarioID): tied indices", file: file, line: line)
        XCTAssertEqual(
            expected.tieBroke,
            selectedIndex.map { _ in tiedIndices.count > 1 },
            "\(scenarioID): tie evidence",
            file: file,
            line: line
        )
        XCTAssertEqual(
            selectedIndex.map { palette[$0].hex },
            expected.selectedHexColor,
            "\(scenarioID): selected color",
            file: file,
            line: line
        )
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
    let scenarios: [ParityScenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case scorer, selection
        case missingPolicy = "missing_policy"
        case lightSources = "light_sources"
        case scenarios
    }
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

    enum CodingKeys: String, CodingKey {
        case channels
        case hexColor = "hex_color"
        case index
    }
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
    let score: ScorerResult

    enum CodingKeys: String, CodingKey {
        case index, score
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        if let value = try? container.decode(Double.self, forKey: .score) {
            score = .score(value)
        } else if try container.decode(String.self, forKey: .score) == "excluded" {
            score = .excluded
        } else {
            throw CorpusFixtureError.invalidScore
        }
    }
}

private enum CorpusFixtureError: Error {
    case invalidHexColor(String)
    case invalidScore
    case unknownLightingCondition(String)
}
