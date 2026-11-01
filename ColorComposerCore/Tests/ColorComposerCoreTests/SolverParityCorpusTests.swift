import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedServerCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertFalse(corpus.scenarios.isEmpty)

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: SolverParityScenario) throws {
        let weights = scenario.weights.channelWeights
        let palette = scenario.palette.map(\.paletteColor)
        let target = TargetResponseVector(scenario.target.channels)
        let scorer = WeightedSquaredErrorScorer()

        for expectedScore in scenario.expected.scores {
            let candidate = try XCTUnwrap(
                palette[safe: expectedScore.index],
                "Corpus score index must address its scenario palette",
                file: #filePath,
                line: #line
            )
            XCTAssertEqual(
                scorer.score(candidate: candidate, target: target, weights: weights),
                expectedScore.result,
                "Score mismatch in corpus scenario \(scenario.id), candidate \(expectedScore.index)"
            )
        }

        let sourceGrids = Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(
                width: 1,
                height: 1,
                values: [scenario.target.channels[condition.rawValue]!]
            ))
        })
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: sourceGrids,
            weights: weights
        )

        XCTAssertEqual(
            result.colorIndex(x: 0, y: 0),
            scenario.expected.selectedIndex,
            "Selection mismatch in corpus scenario \(scenario.id)"
        )
        XCTAssertEqual(
            palette[result.colorIndex(x: 0, y: 0)!].hex,
            scenario.expected.selectedHexColor,
            "Selected color mismatch in corpus scenario \(scenario.id)"
        )
        XCTAssertEqual(
            result.error(x: 0, y: 0),
            scenario.expected.error,
            "Error mismatch in corpus scenario \(scenario.id)"
        )

        if scenario.expected.tieBroke {
            XCTAssertEqual(
                scenario.expected.selectedIndex,
                scenario.expected.tiedIndices.min(),
                "Tie must select the earliest palette index in corpus scenario \(scenario.id)"
            )
        }
    }

    private func loadCorpus() throws -> SolverParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testDirectory.appendingPathComponent("Fixtures/solver-parity-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SolverParityCorpus.self, from: Data(contentsOf: url))
    }
}

private struct SolverParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [SolverParityScenario]
}

private struct SolverParityScenario: Decodable {
    let id: String
    let palette: [SolverParityColor]
    let target: SolverParityColor
    let weights: SolverParityChannels
    let expected: SolverParityExpected
}

private struct SolverParityColor: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]

    var paletteColor: PaletteColor {
        PaletteColor(
            id: index!,
            hex: hexColor,
            rgb: RGBColor(hex: hexColor)!,
            responses: Dictionary(uniqueKeysWithValues: channels.map { name, brightness in
                (LightingCondition(rawValue: name)!, IlluminationResponse(brightness: brightness))
            })
        )
    }
}

private struct SolverParityChannels: Decodable {
    let white: Double?
    let red: Double?
    let green: Double?
    let blue: Double?
    let lps: Double?

    var channelWeights: ChannelWeights {
        ChannelWeights(
            white: white ?? 0,
            red: red ?? 0,
            green: green ?? 0,
            blue: blue ?? 0,
            lps: lps ?? 0
        )
    }
}

private struct SolverParityExpected: Decodable {
    let error: Double
    let scores: [SolverParityScore]
    let selectedIndex: Int
    let selectedHexColor: String
    let tieBroke: Bool
    let tiedIndices: [Int]
}

private struct SolverParityScore: Decodable {
    let index: Int
    let result: ScorerResult

    private enum CodingKeys: String, CodingKey {
        case index
        case score
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        if let score = try? container.decode(Double.self, forKey: .score) {
            result = .score(score)
        } else {
            guard try container.decode(String.self, forKey: .score) == "excluded" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .score,
                    in: container,
                    debugDescription: "Expected a numeric score or the excluded marker."
                )
            }
            result = .excluded
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
