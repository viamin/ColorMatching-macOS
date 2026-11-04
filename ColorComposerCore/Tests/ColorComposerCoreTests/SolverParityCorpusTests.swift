import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedV1Corpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            let palette = scenario.palette.map(makePaletteColor)
            let target = TargetResponseVector(knownChannels(in: scenario.target.channels))
            let weights = makeWeights(scenario.weights)
            let scorer = WeightedSquaredErrorScorer()

            for (candidate, expected) in zip(palette, scenario.expected.scores) {
                assertScore(
                    scorer.score(candidate: candidate, target: target, weights: weights),
                    equals: expected.score,
                    scenarioID: scenario.id,
                    candidateIndex: expected.index
                )
            }

            let selectedIndex = selectedIndex(in: palette, target: target, weights: weights)
            XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(
                selectedIndex.map { palette[$0].hex },
                scenario.expected.selectedHexColor,
                scenario.id
            )

            if weights.activeConditions.allSatisfy({ target.value(for: $0) != nil }) {
                let result = try CompositionSolver().solve(
                    palette: palette,
                    sourceGrids: sourceGrids(from: scenario.target.channels, weights: weights),
                    weights: weights
                )
                XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
                if let expectedError = scenario.expected.error {
                    XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
                } else {
                    XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
                }
            }

            if scenario.expected.tieBroke == true {
                XCTAssertEqual(
                    scenario.expected.selectedIndex,
                    scenario.expected.tiedIndices.min(),
                    "\(scenario.id): ties must select the earliest palette index"
                )
            }
        }
    }

    private func loadCorpus() throws -> SolverParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
        return try JSONDecoder().decode(SolverParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makePaletteColor(_ candidate: SolverParityCorpus.Candidate) -> PaletteColor {
        let responses = knownChannels(in: candidate.channels).compactMapValues { IlluminationResponse(brightness: $0) }
        return PaletteColor(
            id: candidate.index ?? -1,
            hex: candidate.hexColor,
            rgb: RGBColor(hex: candidate.hexColor)!,
            responses: responses
        )
    }

    private func makeWeights(_ weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white"] ?? 0,
            red: weights["red"] ?? 0,
            green: weights["green"] ?? 0,
            blue: weights["blue"] ?? 0,
            lps: weights["lps"] ?? 0
        )
    }

    private func sourceGrids(
        from target: [String: Double],
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid] {
        let channels = knownChannels(in: target)
        Dictionary(uniqueKeysWithValues: weights.activeConditions.map {
            ($0, BrightnessGrid(width: 1, height: 1, fill: channels[$0] ?? 0))
        })
    }

    private func selectedIndex(
        in palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> Int? {
        let scorer = WeightedSquaredErrorScorer()
        var bestIndex: Int?
        var bestScore = Double.infinity
        for (index, candidate) in palette.enumerated() {
            guard case .score(let score) = scorer.score(candidate: candidate, target: target, weights: weights),
                  score < bestScore
            else { continue }
            bestIndex = index
            bestScore = score
        }
        return bestIndex
    }

    private func knownChannels(in channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func assertScore(
        _ actual: ScorerResult,
        equals expected: SolverParityCorpus.Score,
        scenarioID: String,
        candidateIndex: Int
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .value(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "\(scenarioID), candidate \(candidateIndex)")
        default:
            XCTFail("\(scenarioID), candidate \(candidateIndex): expected \(expected), got \(actual)")
        }
    }
}

private struct SolverParityCorpus: Decodable {
    let algorithmVersion: Int
    let selection: String
    let scenarios: [Scenario]

    struct Scenario: Decodable {
        let id: String
        let palette: [Candidate]
        let target: Candidate
        let weights: [String: Double]
        let expected: Expected
    }

    struct Candidate: Decodable {
        let channels: [String: Double]
        let hexColor: String
        let index: Int?
    }

    struct Expected: Decodable {
        let error: Double?
        let scores: [ExpectedScore]
        let selectedHexColor: String?
        let selectedIndex: Int?
        let tieBroke: Bool?
        let tiedIndices: [Int]
    }

    struct ExpectedScore: Decodable {
        let index: Int
        let score: Score
    }

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
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected score or excluded")
            }
        }
    }
}
