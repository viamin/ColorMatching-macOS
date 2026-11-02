import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testCommittedCorpusMetadataDescribesSupportedSolverContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertFalse(corpus.scenarios.isEmpty)
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })
    }

    func testWeightedSquaredErrorScorerReplaysEveryCommittedScenarioExactly() throws {
        for scenario in try loadCorpus().scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario, file: StaticString = #filePath, line: UInt = #line) throws {
        let weights = try makeWeights(scenario.weights)
        let target = TargetResponseVector(try makeResponses(scenario.target.channels))
        let candidates = try scenario.palette
            .sorted { $0.index < $1.index }
            .map(makeCandidate)
        let results = candidates.map {
            WeightedSquaredErrorScorer().score(candidate: $0, target: target, weights: weights)
        }

        XCTAssertEqual(results.count, scenario.expected.scores.count, scenario.id, file: file, line: line)
        for (result, expected) in zip(results, scenario.expected.scores.sorted { $0.index < $1.index }) {
            switch (result, expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .value(let value)):
                XCTAssertEqual(actual, value, "\(scenario.id), candidate \(expected.index)", file: file, line: line)
            default:
                XCTFail("\(scenario.id), candidate \(expected.index): expected \(expected.score), got \(result)", file: file, line: line)
            }
        }

        let selection = selectEarliestMinimum(results)
        XCTAssertEqual(selection.map { candidates[$0.index].id }, scenario.expected.selectedIndex, scenario.id, file: file, line: line)
        XCTAssertEqual(selection?.score, scenario.expected.error, scenario.id, file: file, line: line)
        if let index = selection?.index {
            XCTAssertEqual(candidates[index].hex, scenario.expected.selectedHexColor, scenario.id, file: file, line: line)
        }

        let ties = tiedIndices(in: results, at: selection?.score)
        XCTAssertEqual(ties, scenario.expected.tiedIndices, scenario.id, file: file, line: line)
        let didBreakTie: Bool? = selection == nil ? nil : ties.count > 1
        XCTAssertEqual(didBreakTie, scenario.expected.tieBroke, scenario.id, file: file, line: line)
    }

    private func loadCorpus() throws -> ParityCorpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: url))
    }

    private func makeWeights(_ values: [String: Double]) throws -> ChannelWeights {
        ChannelWeights(
            white: try value("white", in: values), red: try value("red", in: values),
            green: try value("green", in: values), blue: try value("blue", in: values),
            lps: try value("lps", in: values)
        )
    }

    private func makeCandidate(_ entry: ParityCandidate) throws -> PaletteColor {
        PaletteColor(
            id: entry.index, hex: entry.hexColor, rgb: try rgb(from: entry.hexColor),
            responses: try makeResponses(entry.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func makeResponses(_ values: [String: Double]) throws -> [LightingCondition: Double] {
        try LightingCondition.all.reduce(into: [:]) { responses, condition in
            if let brightness = values[condition.rawValue] { responses[condition] = brightness }
        }
    }

    private func value(_ key: String, in values: [String: Double]) throws -> Double {
        guard let value = values[key] else { throw CorpusError.missingWeight(key) }
        return value
    }

    private func rgb(from hex: String) throws -> RGBColor {
        guard let rgb = RGBColor(hex: hex) else { throw CorpusError.invalidHex(hex) }
        return rgb
    }

    private func selectEarliestMinimum(_ results: [ScorerResult]) -> (index: Int, score: Double)? {
        results.enumerated().reduce(nil) { current, result in
            guard case .score(let score) = result.element else { return current }
            guard let current else { return (result.offset, score) }
            return score < current.score ? (result.offset, score) : current
        }
    }

    private func tiedIndices(in results: [ScorerResult], at expectedScore: Double?) -> [Int] {
        guard let expectedScore else { return [] }
        return results.enumerated().compactMap {
            if case .score(let actualScore) = $0.element, actualScore == expectedScore { return $0.offset }
            return nil
        }
    }
}

private enum CorpusError: Error {
    case invalidHex(String)
    case missingWeight(String)
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scenarios: [ParityScenario]
    let scorer: String
    let selection: String
}

private struct ParityScenario: Decodable {
    let expected: ParityExpected
    let id: String
    let palette: [ParityCandidate]
    let target: ParityVector
    let weights: [String: Double]
}

private struct ParityCandidate: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable, CustomStringConvertible {
    let index: Int
    let score: ParityScoreValue

    var description: String { "index \(index): \(score)" }
}

private enum ParityScoreValue: Decodable, CustomStringConvertible {
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
