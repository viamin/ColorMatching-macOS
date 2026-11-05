import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testCommittedWeightedSquaredErrorCorpusMatchesServerSelection() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true }, "The corpus must retain tie cases.")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil }, "The corpus must retain all-excluded cases.")

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: ParityScenario) throws {
        let palette = scenario.palette
            .sorted { $0.index! < $1.index! }
            .map(makeColor)
        let target = TargetResponseVector(scenario.target.channels.compactMapKeys(LightingCondition.init(rawValue:)))
        let weights = makeWeights(scenario.weights)
        let scorer = WeightedSquaredErrorScorer()
        let scores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        for expectedScore in scenario.expected.scores.sorted(by: { $0.index < $1.index }) {
            let actual = scores[expectedScore.index]
            assertScore(actual, equals: expectedScore.score, scenario: scenario.id, index: expectedScore.index)
        }

        let selection = selectEarliestLowestScore(scores)

        XCTAssertEqual(selection.index, scenario.expected.selectedIndex, scenario.id)
        XCTAssertEqual(selection.error, scenario.expected.error, scenario.id)
        XCTAssertEqual(scores.filter { $0 == .excluded }.count, scenario.expected.scores.filter { $0.score == .excluded }.count, scenario.id)

        let actualTies = tiedIndices(in: scores, error: selection.error)
        XCTAssertEqual(actualTies, scenario.expected.tiedIndices, scenario.id)
        XCTAssertEqual(actualTies.count > 1, scenario.expected.tieBroke ?? false, scenario.id)

        if let selectedIndex = scenario.expected.selectedIndex {
            XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor, scenario.id)
            XCTAssertEqual(actualTies.first, selectedIndex, scenario.id)
        }
    }

    private func assertScore(_ actual: ScorerResult, equals expected: ParityScore, scenario: String, index: Int) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, "\(scenario), candidate \(index)")
        default:
            XCTFail("\(scenario), candidate \(index): expected \(expected), got \(actual)")
        }
    }

    private func selectEarliestLowestScore(_ scores: [ScorerResult]) -> (index: Int?, error: Double?) {
        scores.enumerated().reduce((index: Int?.none, error: Double?.none)) { best, candidate in
            guard case .score(let error) = candidate.element else { return best }
            guard let bestError = best.error, bestError <= error else {
                return (candidate.offset, error)
            }
            return best
        }
    }

    private func tiedIndices(in scores: [ScorerResult], error: Double?) -> [Int] {
        guard let error else { return [] }
        return scores.enumerated().compactMap { candidate in
            candidate.element == .score(error) ? candidate.offset : nil
        }
    }

    private func makeColor(_ vector: ParityVector) -> PaletteColor {
        PaletteColor(
            id: vector.index!,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: vector.channels.compactMapKeys(LightingCondition.init(rawValue:)).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func makeWeights(_ weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white", default: 0], red: weights["red", default: 0],
            green: weights["green", default: 0], blue: weights["blue", default: 0],
            lps: weights["lps", default: 0]
        )
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }
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
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityExpectedScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable, Equatable, CustomStringConvertible {
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
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded.")
        }
    }
}

private extension Dictionary where Key == String, Value == Double {
    func compactMapKeys<T: Hashable>(_ transform: (String) -> T?) -> [T: Double] {
        reduce(into: [:]) { result, entry in
            if let key = transform(entry.key) {
                result[key] = entry.value
            }
        }
    }
}
