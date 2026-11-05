import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testCorpusMetadataDescribesTheSharedSolverContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })
    }

    func testWeightedSquaredErrorReplaysEveryCommittedParityScenario() throws {
        for scenario in try loadCorpus().scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: Scenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let target = TargetResponseVector(responseVector(from: scenario.target))
        let weights = channelWeights(from: scenario.weights)
        let candidates = scenario.palette.sorted { $0.index! < $1.index! }
        let scored = candidates.map { candidate in
            (candidate, scorer.score(candidate: paletteColor(from: candidate), target: target, weights: weights))
        }

        XCTAssertEqual(scored.count, scenario.expected.scores.count, scenario.id)
        for (actual, expected) in zip(scored, scenario.expected.scores.sorted { $0.index < $1.index }) {
            XCTAssertEqual(actual.0.index, expected.index, scenario.id)
            assertScore(actual.1, equals: expected.score, scenarioID: scenario.id)
        }

        let ranked = scored.enumerated().compactMap { offset, entry -> (index: Int, color: CorpusVector, score: Double)? in
            guard case .score(let score) = entry.1 else { return nil }
            return (offset, entry.0, score)
        }
        let selected = ranked.dropFirst().reduce(ranked.first) { current, candidate in
            guard let current else { return candidate }
            return candidate.score < current.score ? candidate : current
        }
        let tiedIndices = selected.map { winner in
            ranked.filter { $0.score == winner.score }.map(\.index)
        } ?? []

        XCTAssertEqual(selected?.index, scenario.expected.selectedIndex, scenario.id)
        XCTAssertEqual(selected?.color.hexColor, scenario.expected.selectedHexColor, scenario.id)
        XCTAssertEqual(selected?.score, scenario.expected.error, scenario.id)
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
        let tieBroke: Bool? = selected.map { _ in tiedIndices.count > 1 }
        XCTAssertEqual(scenario.expected.tieBroke, tieBroke, scenario.id)
    }

    private func assertScore(_ actual: ScorerResult, equals expected: ExpectedScore, scenarioID: String) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, scenarioID)
        default:
            XCTFail("\(scenarioID): expected \(expected), got \(actual)")
        }
    }

    private func paletteColor(from vector: CorpusVector) -> PaletteColor {
        PaletteColor(
            id: vector.index!,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: responseVector(from: vector).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func responseVector(from vector: CorpusVector) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: vector.channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func channelWeights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0],
            red: values["red", default: 0],
            green: values["green", default: 0],
            blue: values["blue", default: 0],
            lps: values["lps", default: 0]
        )
    }

    private func loadCorpus() throws -> ParityCorpus {
        try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: corpusURL))
    }

    private var corpusURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Parity/v1/corpus.json")
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: CorpusVector
    let palette: [CorpusVector]
    let expected: ExpectedScenario
}

private struct CorpusVector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ExpectedScenario: Decodable {
    let error: Double?
    let scores: [ExpectedCandidateScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ExpectedCandidateScore: Decodable {
    let index: Int
    let score: ExpectedScore
}

private enum ExpectedScore: Decodable, CustomStringConvertible {
    case excluded
    case score(Double)

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .score(let value): return String(value)
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
