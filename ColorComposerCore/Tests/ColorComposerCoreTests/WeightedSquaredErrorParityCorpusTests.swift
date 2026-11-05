import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the versioned golden vectors produced by
/// `viamin/color_matching`'s `mix parity.generate` task. The fixture is kept
/// beside this test rather than fetched at test time so a server revision
/// cannot silently alter the contract under test.
final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorScorerMatchesParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1, "Update this test with an intentional corpus-version migration.")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = TargetResponseVector(responses(from: scenario.target.channels))
            let weights = weights(from: scenario.weights)
            let palette = try scenario.palette.map(makePaletteColor)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            assertScores(actualScores, match: scenario.expected.scores, scenarioID: scenario.id)
            assertSelection(
                actualScores,
                palette: palette,
                matches: scenario.expected,
                scenarioID: scenario.id
            )
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory.appendingPathComponent("Fixtures-parity-corpus-v1.json")
        let data = try Data(contentsOf: fixture)
        return try JSONDecoder().decode(ParityCorpus.self, from: data)
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func weights(from channels: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: channels["white"] ?? 0,
            red: channels["red"] ?? 0,
            green: channels["green"] ?? 0,
            blue: channels["blue"] ?? 0,
            lps: channels["lps"] ?? 0
        )
    }

    private func makePaletteColor(_ vector: ParityVector) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: vector.hexColor), "Invalid corpus color \(vector.hexColor)")
        let responseValues = responses(from: vector.channels)
        return PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: rgb,
            responses: responseValues.mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func assertScores(
        _ actual: [ScorerResult],
        match expected: [ExpectedScore],
        scenarioID: String
    ) {
        XCTAssertEqual(actual.count, expected.count, "\(scenarioID): candidate count")
        for expectedScore in expected {
            let actualScore = actual[expectedScore.index]
            switch (actualScore, expectedScore.score) {
            case (.excluded, .excluded):
                continue
            case (.score(let actualValue), .value(let expectedValue)):
                XCTAssertEqual(actualValue, expectedValue, accuracy: 1e-12, "\(scenarioID): score at \(expectedScore.index)")
            default:
                XCTFail("\(scenarioID): score at \(expectedScore.index) did not match \(expectedScore.score)")
            }
        }
    }

    private func assertSelection(
        _ scores: [ScorerResult],
        palette: [PaletteColor],
        matches expected: ExpectedOutcome,
        scenarioID: String
    ) {
        var selected: (index: Int, score: Double)?
        for (index, result) in scores.enumerated() {
            guard case .score(let score) = result else { continue }
            if selected == nil || score < selected!.score {
                selected = (index, score)
            }
        }

        XCTAssertEqual(selected?.index, expected.selectedIndex, "\(scenarioID): selected index")
        XCTAssertEqual(selected.map { palette[$0.index].hex }, expected.selectedHexColor, "\(scenarioID): selected color")
        if let expectedError {
            guard let selected else {
                return XCTFail("\(scenarioID): expected a selected candidate")
            }
            XCTAssertEqual(selected.score, expectedError, accuracy: 1e-12, "\(scenarioID): selected error")
        } else {
            XCTAssertNil(selected, "\(scenarioID): expected every candidate to be excluded")
        }

        let tiedIndices = selected.map { selected in
            scores.enumerated().compactMap { index, result in
                guard case .score(let score) = result, score == selected.score else { return nil }
                return index
            }
        } ?? []
        XCTAssertEqual(tiedIndices, expected.tiedIndices, "\(scenarioID): tied candidates")
        XCTAssertEqual(tiedIndices.count > 1, expected.tieBroke, "\(scenarioID): tie-break evidence")
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [ParityScenario]

    private enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case missingPolicy = "missing_policy"
        case scenarios
    }
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ExpectedOutcome
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?

    private enum CodingKeys: String, CodingKey {
        case channels
        case hexColor = "hex_color"
        case index
    }
}

private struct ExpectedOutcome: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool
    let tiedIndices: [Int]

    private enum CodingKeys: String, CodingKey {
        case error
        case scores
        case selectedHexColor = "selected_hex_color"
        case selectedIndex = "selected_index"
        case tieBroke = "tie_broke"
        case tiedIndices = "tied_indices"
    }
}

private struct ExpectedScore: Decodable {
    enum Score: Decodable, CustomStringConvertible {
        case excluded
        case value(Double)

        var description: String {
            switch self {
            case .excluded: return "excluded"
            case .value(let value): return String(value)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                self = .value(value)
            } else if try container.decode(String.self) == "excluded" {
                self = .excluded
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
            }
        }
    }

    let index: Int
    let score: Score
}
