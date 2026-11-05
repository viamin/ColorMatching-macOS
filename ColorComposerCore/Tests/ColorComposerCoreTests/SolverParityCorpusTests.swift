import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the authoritative server corpus rather than duplicating scoring
/// expectations in Swift. The fixture is copied verbatim from
/// `viamin/color_matching`'s `priv/parity/v1/corpus.json`.
final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesEveryCorpusCandidate() throws {
        for scenario in try loadCorpus().scenarios {
            let scorer = WeightedSquaredErrorScorer()
            let target = TargetResponseVector(channels(scenario.target.channels))
            let weights = makeWeights(scenario.weights)

            for candidate in scenario.palette {
                let actual = scorer.score(
                    candidate: makeColor(candidate),
                    target: target,
                    weights: weights
                )
                assert(actual, matches: expectedScore(for: candidate.index!, in: scenario), scenario: scenario.id)
            }
        }
    }

    func testSolverSelectionMatchesEveryCorpusScenarioIncludingTies() throws {
        for scenario in try loadCorpus().scenarios {
            let weights = makeWeights(scenario.weights)
            let active = weights.activeConditions
            let targetChannels = channels(scenario.target.channels)
            if active.contains(where: { targetChannels[$0] == nil }) {
                // CompositionSolver always receives a source grid for each
                // active channel, so it cannot represent this malformed target.
                // Candidate-level replay above verifies the server's exclusion.
                continue
            }
            let grids = Dictionary(uniqueKeysWithValues: active.map {
                ($0, BrightnessGrid(width: 1, height: 1, values: [targetChannels[$0] ?? 0]))
            })

            let result = try CompositionSolver().solve(
                palette: scenario.palette.map(makeColor),
                sourceGrids: grids,
                weights: weights
            )

            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
            if let expectedError = scenario.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
            }

            if scenario.expected.tieBroke == true {
                XCTAssertEqual(scenario.expected.selectedIndex, scenario.expected.tiedIndices.first, scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let source = URL(fileURLWithPath: #filePath)
        let fixture = source.deletingLastPathComponent().appendingPathComponent("Fixtures/solver-parity-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makeColor(_ vector: CorpusVector) -> PaletteColor {
        PaletteColor(
            id: vector.index ?? 0,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: channels(vector.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func makeWeights(_ values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func channels(_ values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { name, value in
            guard let condition = LightingCondition(rawValue: name) else { return nil }
            return (condition, value)
        })
    }

    private func expectedScore(for index: Int, in scenario: CorpusScenario) -> CorpusScore {
        scenario.expected.scores.first(where: { $0.index == index })!.score
    }

    private func assert(_ actual: ScorerResult, matches expected: CorpusScore, scenario: String) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .value(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario)
        default:
            XCTFail("\\(scenario): expected \\(expected), got \\(actual)")
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scenarios: [CorpusScenario]
}

private struct CorpusScenario: Decodable {
    let id: String
    let palette: [CorpusVector]
    let target: CorpusVector
    let weights: [String: Double]
    let expected: CorpusExpected
}

private struct CorpusVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct CorpusExpected: Decodable {
    let error: Double?
    let scores: [IndexedScore]
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct IndexedScore: Decodable {
    let index: Int
    let score: CorpusScore
}

private enum CorpusScore: Decodable, CustomStringConvertible {
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
