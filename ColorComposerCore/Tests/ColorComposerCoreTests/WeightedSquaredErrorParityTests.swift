import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testCorpusMetadataDescribesTheSharedSolverContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })
    }

    func testWeightedSquaredErrorScorerReplaysEveryParityScenarioExactly() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            try XCTContext.runActivity(named: scenario.id) { _ in
                try assertScenario(scenario, with: scorer)
            }
        }
    }

    private func assertScenario(_ scenario: ParityScenario, with scorer: WeightedSquaredErrorScorer) throws {
        let candidates = scenario.palette
            .sorted { $0.index! < $1.index! }
            .map(makePaletteColor)
        let target = TargetResponseVector(responseValues(from: scenario.target.channels))
        let weights = makeWeights(from: scenario.weights)
        let actualScores = candidates.map {
            scorer.score(candidate: $0, target: target, weights: weights)
        }

        XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
        for (actual, expected) in zip(actualScores, scenario.expected.scores.sorted { $0.index < $1.index }) {
            assert(actual, matches: expected.score, scenarioID: scenario.id)
        }

        let selection = selectEarliestScore(from: actualScores)
        XCTAssertEqual(selection.index, scenario.expected.selectedIndex, scenario.id)

        if let selectedIndex = scenario.expected.selectedIndex {
            XCTAssertEqual(candidates[selectedIndex].hex, scenario.expected.selectedHexColor, scenario.id)
            XCTAssertEqual(selection.error, scenario.expected.error, scenario.id)
        } else {
            XCTAssertNil(selection.error, scenario.id)
        }

        let tiedIndices = actualScores.enumerated().compactMap { index, result -> Int? in
            guard case .score(let score) = result, score == selection.error else { return nil }
            return index
        }
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
        XCTAssertEqual(scenario.expected.tieBroke, tiedIndices.count > 1, scenario.id)
    }

    private func assert(
        _ actual: ScorerResult,
        matches expected: ParityScore,
        scenarioID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, scenarioID, file: file, line: line)
        default:
            XCTFail("\(scenarioID): expected \(expected), got \(actual)", file: file, line: line)
        }
    }

    private func selectEarliestScore(from scores: [ScorerResult]) -> (index: Int?, error: Double?) {
        var selectedIndex: Int?
        var selectedError = Double.infinity

        for (index, result) in scores.enumerated() {
            guard case .score(let error) = result, error < selectedError else { continue }
            selectedIndex = index
            selectedError = error
        }

        return (selectedIndex, selectedIndex.map { _ in selectedError })
    }

    private func makePaletteColor(_ vector: ParityVector) -> PaletteColor {
        PaletteColor(
            id: vector.index!,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: responseValues(from: vector.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func responseValues(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: LightingCondition.all.compactMap { condition in
            channels[condition.rawValue].map { (condition, $0) }
        })
    }

    private func makeWeights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func loadCorpus() throws -> ParityCorpus {
        let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let corpusURL = sourceDirectory.appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: corpusURL))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpectation
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ParityExpectation: Decodable {
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

private enum ParityScore: Decodable, CustomStringConvertible {
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
