import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedColorMatchingCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            let weights = ChannelWeights(channels: scenario.weights)
            let target = TargetResponseVector(channels: scenario.target.channels)
            let palette = try scenario.palette.map(makeColor)
            let scorer = WeightedSquaredErrorScorer()

            for candidate in scenario.palette {
                let expectedScore = try XCTUnwrap(scenario.expected.scores.first { $0.index == candidate.index })
                let result = scorer.score(
                    candidate: try makeColor(candidate), target: target, weights: weights
                )
                assert(result, matches: expectedScore.score, scenarioID: scenario.id, candidateIndex: candidate.index)
            }

            let result = try solve(palette: palette, target: target, weights: weights)
            XCTAssertEqual(result.index, scenario.expected.selectedIndex, "scenario=\(scenario.id)")
            XCTAssertEqual(result.hex, scenario.expected.selectedHexColor, "scenario=\(scenario.id)")
            switch (result.error, scenario.expected.error) {
            case (nil, nil):
                break
            case (let actual?, let expected?):
                XCTAssertEqual(actual, expected, accuracy: 1e-12, "scenario=\(scenario.id)")
            default:
                XCTFail("scenario=\(scenario.id): expected error \(String(describing: scenario.expected.error)), got \(String(describing: result.error))")
            }

            if scenario.expected.tieBroke == true {
                XCTAssertEqual(result.index, scenario.expected.tiedIndices.first, "scenario=\(scenario.id)")
            }
        }
    }

    private func solve(
        palette: [PaletteColor], target: TargetResponseVector, weights: ChannelWeights
    ) throws -> (index: Int?, hex: String?, error: Double?) {
        let scorer = WeightedSquaredErrorScorer()
        let scores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
        let selection = scores.enumerated().compactMap { index, score -> (Int, Double)? in
            guard case .score(let value) = score else { return nil }
            return (index, value)
        }.min { $0.1 < $1.1 }

        guard let selection else { return (nil, nil, nil) }
        return (selection.0, palette[selection.0].hex, selection.1)
    }

    private func makeColor(_ fixture: CandidateFixture) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: fixture.hexColor), "Invalid fixture hex \(fixture.hexColor)")
        let responses = fixture.channels.reduce(into: [LightingCondition: IlluminationResponse]()) {
            $0[LightingCondition(fixtureName: $1.key)] = IlluminationResponse(brightness: $1.value)
        }
        return PaletteColor(id: fixture.index, hex: fixture.hexColor, rgb: rgb, responses: responses)
    }

    private func assert(
        _ result: ScorerResult, matches expected: ScoreFixture, scenarioID: String, candidateIndex: Int
    ) {
        switch (result, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "scenario=\(scenarioID), candidate=\(candidateIndex)")
        default:
            XCTFail("scenario=\(scenarioID), candidate=\(candidateIndex): expected \(expected), got \(result)")
        }
    }

    private func loadCorpus() throws -> CorpusFixture {
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/color_matching_solver_parity_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CorpusFixture.self, from: Data(contentsOf: fileURL))
    }
}

private extension ChannelWeights {
    init(channels: [String: Double]) {
        self.init(
            white: channels["white"] ?? 0,
            red: channels["red"] ?? 0,
            green: channels["green"] ?? 0,
            blue: channels["blue"] ?? 0,
            lps: channels["lps"] ?? 0
        )
    }
}

private extension TargetResponseVector {
    init(channels: [String: Double]) {
        self.init(channels.reduce(into: [LightingCondition: Double]()) {
            $0[LightingCondition(fixtureName: $1.key)] = $1.value
        })
    }
}

private extension LightingCondition {
    init(fixtureName: String) {
        switch fixtureName {
        case "white": self = .white
        case "red": self = .red
        case "green": self = .green
        case "blue": self = .blue
        case "lps": self = .lps
        default: preconditionFailure("Unknown corpus light source: \(fixtureName)")
        }
    }
}

private struct CorpusFixture: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let scenarios: [ScenarioFixture]
}

private struct ScenarioFixture: Decodable {
    let id: String
    let palette: [CandidateFixture]
    let target: TargetFixture
    let weights: [String: Double]
    let expected: ExpectedFixture
}

private struct CandidateFixture: Decodable {
    let index: Int
    let hexColor: String
    let channels: [String: Double]
}

private struct TargetFixture: Decodable {
    let channels: [String: Double]
}

private struct ExpectedFixture: Decodable {
    let error: Double?
    let scores: [CandidateScoreFixture]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct CandidateScoreFixture: Decodable {
    let index: Int
    let score: ScoreFixture
}

private enum ScoreFixture: Decodable, CustomStringConvertible {
    case excluded
    case score(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .score(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected score or excluded")
        }
    }

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .score(let value): return "score(\(value))"
        }
    }
}
