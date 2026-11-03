import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = TargetResponseVector(channelValues(scenario.target.channels))
            let weights = ChannelWeights(channelValues(scenario.weights))
            let palette = try scenario.palette.map(makeColor)

            for (position, candidate) in palette.enumerated() {
                let expected = scenario.expected.scores.first { $0.index == position }
                XCTAssertNotNil(expected, "Missing score for \(scenario.id) candidate \(position)")
                assert(
                    scorer.score(candidate: candidate, target: target, weights: weights),
                    matches: expected?.score,
                    scenario: scenario.id,
                    candidate: position
                )
            }

            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: sourceGrids(for: scenario.target.channels),
                weights: weights
            )
            XCTAssertEqual(
                result.colorIndex(x: 0, y: 0),
                scenario.expected.selectedIndex,
                "Selection mismatch for \(scenario.id)"
            )
            if let expectedError = scenario.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
            }
            XCTAssertEqual(
                result.excludedCandidateCount,
                scenario.expected.scores.filter { $0.score == .excluded }.count,
                "Exclusion count mismatch for \(scenario.id)"
            )
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testDirectory.appendingPathComponent("Resources/solver-parity-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }

    private func makeColor(_ candidate: ParityCandidate) throws -> PaletteColor {
        PaletteColor(
            id: candidate.index,
            hex: candidate.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: candidate.hexColor)),
            responses: channelValues(candidate.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func sourceGrids(for channels: [String: Double]) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: channelValues(channels).map {
            ($0.key, BrightnessGrid(width: 1, height: 1, values: [$0.value]))
        })
    }

    private func channelValues(_ channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, value in
            LightingCondition(rawValue: name).map { ($0, value) }
        })
    }

    private func assert(
        _ result: ScorerResult,
        matches expected: ParityScore?,
        scenario: String,
        candidate: Int
    ) {
        switch (result, expected) {
        case (.excluded, .excluded):
            return
        case (.score(let actual), .value(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "\(scenario) candidate \(candidate)")
        default:
            XCTFail("\(scenario) candidate \(candidate): expected \(String(describing: expected)), got \(result)")
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityCandidate]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityCandidate: Decodable {
    let index: Int
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedIndex: Int?
}

private struct ParityExpectedScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable, Equatable {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(Double.self) {
            self = .value(value)
        } else {
            let value = try decoder.singleValueContainer().decode(String.self)
            guard value == "excluded" else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Unsupported parity score: \(value)"
                )
            }
            self = .excluded
        }
    }
}
