import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedServerCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertScorerParity(for: scenario)
            try assertSolverParityWhenTargetIsComplete(for: scenario)
        }
    }

    private func assertScorerParity(for scenario: Scenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let target = TargetResponseVector(channelValues(scenario.target.channels))
        let weights = makeWeights(scenario.weights)
        let scores = scenario.palette.map {
            scorer.score(candidate: makeColor($0), target: target, weights: weights)
        }

        XCTAssertEqual(scores.count, scenario.expected.scores.count, scenario.id)
        for (candidateIndex, pair) in zip(scores, scenario.expected.scores).enumerated() {
            let (actual, expected) = pair
            XCTAssertEqual(expected.index, candidateIndex, scenario.id)
            switch (actual, expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .value(let expected)):
                XCTAssertEqual(actual, expected, scenario.id + " candidate \(expected.index)")
            default:
                XCTFail("\(scenario.id) candidate \(expected.index) score mismatch")
            }
        }

        let selected = scores.enumerated().compactMap { index, score -> (Int, Double)? in
            guard case .score(let score) = score else { return nil }
            return (index, score)
        }.min { $0.1 < $1.1 }

        XCTAssertEqual(selected?.0, scenario.expected.selectedIndex, scenario.id)
        XCTAssertEqual(selected?.1, scenario.expected.error, scenario.id)
        XCTAssertEqual(selected?.0, scenario.expected.tiedIndices.first, scenario.id)
    }

    private func assertSolverParityWhenTargetIsComplete(for scenario: Scenario) throws {
        let weights = makeWeights(scenario.weights)
        guard weights.activeConditions.allSatisfy({ scenario.target.channels[$0.rawValue] != nil }) else {
            return
        }

        let sourceGrids = Dictionary(uniqueKeysWithValues: weights.activeConditions.map {
            ($0, BrightnessGrid(width: 1, height: 1, fill: scenario.target.channels[$0.rawValue]!))
        })
        let result = try CompositionSolver().solve(
            palette: scenario.palette.map(makeColor),
            sourceGrids: sourceGrids,
            weights: weights
        )

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
        if let expectedError = scenario.expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, scenario.id)
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
        }
        XCTAssertEqual(result.excludedCandidateCount, scenario.expected.scores.filter { $0.score == .excluded }.count, scenario.id)
    }

    private func loadCorpus() throws -> Corpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixture = testFile.deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: fixture))
    }

    private func makeColor(_ entry: PaletteEntry) -> PaletteColor {
        let responses = channelValues(entry.channels).mapValues { IlluminationResponse(brightness: $0) }
        return PaletteColor(id: entry.index, hex: entry.hexColor, rgb: RGBColor(hex: entry.hexColor)!, responses: responses)
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

    private func channelValues(_ values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: VectorEntry
    let palette: [PaletteEntry]
    let expected: Expected
}

private struct VectorEntry: Decodable {
    let channels: [String: Double]
}

private struct PaletteEntry: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int
}

private struct Expected: Decodable {
    let error: Double?
    let scores: [CandidateScore]
    let selectedIndex: Int?
    let tiedIndices: [Int]
}

private struct CandidateScore: Decodable {
    enum Score: Equatable {
        case excluded
        case value(Double)
    }

    let index: Int
    let score: Score

    private enum CodingKeys: String, CodingKey {
        case index
        case score
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        if let value = try? container.decode(Double.self, forKey: .score) {
            score = .value(value)
            return
        }

        guard try container.decode(String.self, forKey: .score) == "excluded" else {
            throw DecodingError.dataCorruptedError(
                forKey: .score,
                in: container,
                debugDescription: "Candidate score must be a number or excluded."
            )
        }
        score = .excluded
    }
}
