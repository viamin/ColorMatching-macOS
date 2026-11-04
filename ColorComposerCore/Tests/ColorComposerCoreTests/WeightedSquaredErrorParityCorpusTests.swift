import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testCommittedCorpusMatchesWeightedSquaredErrorAndDefaultSolver() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(
        _ scenario: ParityScenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let weights = makeWeights(scenario.weights)
        let target = makeTarget(scenario.target)
        let palette = try scenario.palette
            .sorted { $0.index < $1.index }
            .map(makeColor)
        let scorer = WeightedSquaredErrorScorer()
        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id, file: file, line: line)
        for (actual, expected) in zip(actualScores, scenario.expected.scores.sorted { $0.index < $1.index }) {
            assertScore(actual, matches: expected.score, scenarioID: scenario.id, file: file, line: line)
        }

        let selected = selectedIndex(from: actualScores)
        XCTAssertEqual(selected.index, scenario.expected.selectedIndex, scenario.id, file: file, line: line)
        if let index = selected.index {
            XCTAssertEqual(palette[index].hex, scenario.expected.selectedHexColor, scenario.id, file: file, line: line)
            XCTAssertEqual(selected.error, scenario.expected.error, accuracy: 1e-15, scenario.id, file: file, line: line)
        } else {
            XCTAssertNil(scenario.expected.selectedHexColor, scenario.id, file: file, line: line)
            XCTAssertNil(scenario.expected.error, scenario.id, file: file, line: line)
        }

        assertTieEvidence(actualScores, selectedError: selected.error, expected: scenario.expected, scenarioID: scenario.id)
        try assertDefaultSolverSelection(
            scenario,
            weights: weights,
            palette: palette,
            file: file,
            line: line
        )
    }

    private func assertDefaultSolverSelection(
        _ scenario: ParityScenario,
        weights: ChannelWeights,
        palette: [PaletteColor],
        file: StaticString,
        line: UInt
    ) throws {
        let active = weights.activeConditions
        guard active.allSatisfy({ scenario.target.channels[\($0.rawValue)] != nil }) else {
            return
        }

        let sourceGrids = Dictionary(uniqueKeysWithValues: active.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, fill: scenario.target.channels[condition.rawValue]!))
        })
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: sourceGrids, weights: weights)

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id, file: file, line: line)
        XCTAssertEqual(result.error(x: 0, y: 0), scenario.expected.error ?? .infinity, accuracy: 1e-15, scenario.id, file: file, line: line)
    }

    private func assertScore(
        _ actual: ScorerResult,
        matches expected: ParityScore,
        scenarioID: String,
        file: StaticString,
        line: UInt
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-15, scenarioID, file: file, line: line)
        default:
            XCTFail("\(scenarioID): expected \(expected), received \(actual)", file: file, line: line)
        }
    }

    private func assertTieEvidence(
        _ scores: [ScorerResult],
        selectedError: Double?,
        expected: ParityExpected,
        scenarioID: String
    ) {
        let tiedIndices = scores.enumerated().compactMap { index, score -> Int? in
            guard case .score(let value) = score, value == selectedError else { return nil }
            return index
        }

        XCTAssertEqual(tiedIndices, expected.tiedIndices, scenarioID)
        if selectedError == nil {
            XCTAssertNil(expected.tieBroke, scenarioID)
        } else {
            XCTAssertEqual(expected.tieBroke, tiedIndices.count > 1, scenarioID)
        }
    }

    private func selectedIndex(from scores: [ScorerResult]) -> (index: Int?, error: Double?) {
        var selected: (index: Int, error: Double)?
        for (index, score) in scores.enumerated() {
            guard case .score(let error) = score else { continue }
            if selected == nil || error < selected!.error {
                selected = (index, error)
            }
        }
        return (selected?.index, selected?.error)
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

    private func makeTarget(_ vector: ParityVector) -> TargetResponseVector {
        TargetResponseVector(Dictionary(uniqueKeysWithValues: LightingCondition.all.compactMap { condition in
            vector.channels[condition.rawValue].map { (condition, $0) }
        }))
    }

    private func makeColor(_ vector: ParityVector) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: vector.hexColor), "Corpus colors must have valid hex values")
        let responses = Dictionary(uniqueKeysWithValues: LightingCondition.all.compactMap { condition in
            vector.channels[condition.rawValue].map { (condition, IlluminationResponse(brightness: $0)) }
        })
        return PaletteColor(id: vector.index ?? 0, hex: vector.hexColor, rgb: rgb, responses: responses)
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let corpusURL = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_parity_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: corpusURL))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: ParityVector
    let palette: [ParityVector]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityIndexedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityIndexedScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable, CustomStringConvertible {
    case excluded
    case score(Double)

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .score(let value): return "score(\(value))"
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
