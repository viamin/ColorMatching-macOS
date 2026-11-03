import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testMatchesCommittedColorMatchingParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)

        for scenario in corpus.scenarios {
            try assertCandidateScoresMatch(scenario)
            try assertSelectionMatches(scenario)
        }
    }

    private func assertCandidateScoresMatch(_ scenario: ParityScenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let target = makeTarget(scenario.target)
        let weights = makeWeights(scenario.weights)

        for expected in scenario.expected.scores {
            let candidate = try XCTUnwrap(
                scenario.palette.first(where: { $0.index == expected.index }),
                "Missing candidate \(expected.index) in \(scenario.id)"
            )
            let result = scorer.score(candidate: makeColor(candidate), target: target, weights: weights)

            switch (expected.score, result) {
            case (.excluded, .excluded):
                break
            case (.value(let expected), .score(let actual)):
                XCTAssertEqual(actual, expected, accuracy: 1e-12, "\(scenario.id), candidate \(candidate.index)")
            default:
                XCTFail("\(scenario.id), candidate \(candidate.index): expected \(expected.score), got \(result)")
            }
        }
    }

    private func assertSelectionMatches(_ scenario: ParityScenario) throws {
        guard let expectedIndex = scenario.expected.selectedIndex else { return }
        let expectedError = try XCTUnwrap(scenario.expected.error, "Missing expected error in \(scenario.id)")

        let result = try CompositionSolver().solve(
            palette: scenario.palette.map(makeColor),
            sourceGrids: sourceGrids(for: scenario.target),
            weights: makeWeights(scenario.weights)
        )

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), expectedIndex, scenario.id)
        XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
        XCTAssertEqual(
            scenario.expected.tiedIndices.first,
            expectedIndex,
            "\(scenario.id) must preserve the server's earliest-candidate tie selection"
        )
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-parity-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makeColor(_ candidate: ParityCandidate) -> PaletteColor {
        PaletteColor(
            id: candidate.index,
            hex: candidate.hexColor,
            rgb: RGBColor(hex: candidate.hexColor)!,
            responses: responses(from: candidate.channels)
        )
    }

    private func makeTarget(_ target: ParityTarget) -> TargetResponseVector {
        TargetResponseVector(target.channels.reduce(into: [:]) { responses, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            responses[condition] = entry.value
        })
    }

    private func sourceGrids(for target: ParityTarget) -> [LightingCondition: BrightnessGrid] {
        target.channels.reduce(into: [:]) { grids, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            grids[condition] = BrightnessGrid(width: 1, height: 1, values: [entry.value])
        }
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        channels.reduce(into: [:]) { responses, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            responses[condition] = IlluminationResponse(brightness: entry.value)
        }
    }

    private func makeWeights(_ channels: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: channels["white", default: 0],
            red: channels["red", default: 0],
            green: channels["green", default: 0],
            blue: channels["blue", default: 0],
            lps: channels["lps", default: 0]
        )
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityCandidate]
    let target: ParityTarget
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityCandidate: Decodable {
    let index: Int
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityTarget: Decodable {
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedIndex: Int?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ExpectedScore
}

private enum ExpectedScore: Decodable, CustomStringConvertible {
    case excluded
    case value(Double)

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

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .value(let value): return String(value)
        }
    }
}
