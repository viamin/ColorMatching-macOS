import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the versioned golden vectors emitted by `color_matching`.
///
/// The fixture is deliberately committed with the tests so solver changes are
/// reviewed against the server contract, including exact ties and exclusions.
final class SolverParityCorpusTests: XCTestCase {
    func testCorpusMetadataDescribesTheSharedSolverContract() throws {
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

    func testWeightedSquaredErrorSelectionsMatchParityCorpusExactly() throws {
        let scorer = WeightedSquaredErrorScorer()

        for scenario in try loadCorpus().scenarios {
            let weights = scenario.weights.channelWeights
            let target = TargetResponseVector(scenario.target.responses)
            let palette = scenario.palette.enumerated().map { index, vector in
                vector.paletteColor(id: index)
            }
            let results = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            assertScores(results, match: scenario.expected.scores, scenario: scenario.id)
            assertSelection(results, palette: palette, match: scenario.expected, scenario: scenario.id)
        }
    }

    private func assertScores(
        _ results: [ScorerResult],
        match expected: [CorpusScore],
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(results.count, expected.count, "\(scenario): score count", file: file, line: line)

        for (result, expectedScore) in zip(results, expected) {
            switch (result, expectedScore.value) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .score(let expected)):
                XCTAssertEqual(actual, expected, "\(scenario): score at index \(expectedScore.index)", file: file, line: line)
            default:
                XCTFail("\(scenario): score at index \(expectedScore.index) disagrees with corpus", file: file, line: line)
            }
        }
    }

    private func assertSelection(
        _ results: [ScorerResult],
        palette: [PaletteColor],
        match expected: CorpusExpected,
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let selection = earliestSelection(from: results)
        let tiedIndices = tiedIndices(in: results, selectedScore: selection?.score)

        XCTAssertEqual(tiedIndices, expected.tiedIndices, "\(scenario): tied indices", file: file, line: line)
        XCTAssertEqual(expected.tieBroke, tiedIndices.count > 1, "\(scenario): tie evidence", file: file, line: line)

        guard let expectedIndex = expected.selectedIndex else {
            XCTAssertNil(selection, "\(scenario): expected no selection", file: file, line: line)
            return
        }

        let selected = try? XCTUnwrap(selection, "\(scenario): expected a selection", file: file, line: line)
        XCTAssertEqual(selected?.index, expectedIndex, "\(scenario): selected index", file: file, line: line)
        XCTAssertEqual(selected?.score, expected.error, "\(scenario): selected error", file: file, line: line)
        XCTAssertEqual(palette[expectedIndex].hex, expected.selectedHexColor, "\(scenario): selected color", file: file, line: line)
    }

    private func earliestSelection(from results: [ScorerResult]) -> (index: Int, score: Double)? {
        var best: (index: Int, score: Double)?

        for (index, result) in results.enumerated() {
            guard case .score(let score) = result else { continue }
            if best == nil || score < best!.score {
                best = (index, score)
            }
        }
        return best
    }

    private func tiedIndices(in results: [ScorerResult], selectedScore: Double?) -> [Int] {
        guard let selectedScore else { return [] }

        return results.enumerated().compactMap { index, result in
            guard case .score(let score) = result, score == selectedScore else { return nil }
            return index
        }
    }

    private func loadCorpus() throws -> SolverParityCorpus {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/SolverParity/v1/corpus.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SolverParityCorpus.self, from: Data(contentsOf: path))
    }
}

private struct SolverParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
    let scenarios: [CorpusScenario]
}

private struct CorpusScenario: Decodable {
    let id: String
    let weights: CorpusChannels
    let target: CorpusVector
    let palette: [CorpusVector]
    let expected: CorpusExpected
}

private struct CorpusExpected: Decodable {
    let error: Double?
    let scores: [CorpusScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct CorpusScore: Decodable {
    enum Value: Equatable {
        case excluded
        case score(Double)
    }

    let index: Int
    let value: Value

    private enum CodingKeys: String, CodingKey { case index, score }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        if let score = try? container.decode(Double.self, forKey: .score) {
            value = .score(score)
        } else {
            let marker = try container.decode(String.self, forKey: .score)
            guard marker == "excluded" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .score,
                    in: container,
                    debugDescription: "Expected a numeric score or excluded marker."
                )
            }
            value = .excluded
        }
    }
}

private struct CorpusVector: Decodable {
    let hexColor: String
    let channels: CorpusChannels

    var responses: [LightingCondition: Double] { channels.responses }

    func paletteColor(id: Int) -> PaletteColor {
        PaletteColor(
            id: id,
            hex: hexColor,
            rgb: RGBColor(hex: hexColor)!,
            responses: responses.mapValues { IlluminationResponse(brightness: $0) }
        )
    }
}

private struct CorpusChannels: Decodable {
    let white: Double?
    let red: Double?
    let green: Double?
    let blue: Double?
    let lps: Double?

    var channelWeights: ChannelWeights {
        ChannelWeights(white: white ?? 0, red: red ?? 0, green: green ?? 0, blue: blue ?? 0, lps: lps ?? 0)
    }

    var responses: [LightingCondition: Double] {
        [
            .white: white,
            .red: red,
            .green: green,
            .blue: blue,
            .lps: lps
        ].compactMapValues { $0 }
    }
}
