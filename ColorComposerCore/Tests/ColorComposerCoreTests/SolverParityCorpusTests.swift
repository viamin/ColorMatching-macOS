import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedServerParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: ParityScenario, file: StaticString = #filePath, line: UInt = #line) throws {
        let scorer = WeightedSquaredErrorScorer()
        let target = TargetResponseVector(responses(from: scenario.target.channels))
        let weights = ChannelWeights(values: scenario.weights)
        let palette = scenario.palette.map(paletteColor)
        let results = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(
            scenario.palette.map(\.index),
            Array(scenario.palette.indices).map(Optional.some),
            scenario.id,
            file: file,
            line: line
        )
        XCTAssertEqual(scenario.expected.scores.map(\.index), Array(scenario.palette.indices), scenario.id, file: file, line: line)
        XCTAssertEqual(results, scenario.expected.scores.map(ScorerResult.init), scenario.id, file: file, line: line)

        let selection = earliestMinimum(in: results)
        XCTAssertEqual(selection.index, scenario.expected.selectedIndex, scenario.id, file: file, line: line)
        XCTAssertEqual(selection.error, scenario.expected.error, scenario.id, file: file, line: line)
        XCTAssertEqual(selection.tiedIndices, scenario.expected.tiedIndices, scenario.id, file: file, line: line)
        let tieBroke = selection.index.map { _ in selection.tiedIndices.count > 1 }
        XCTAssertEqual(tieBroke, scenario.expected.tieBroke, scenario.id, file: file, line: line)

        let selectedHex = selection.index.map { scenario.palette[$0].hexColor }
        XCTAssertEqual(selectedHex, scenario.expected.selectedHexColor, scenario.id, file: file, line: line)

        try assertSolverSelection(
            palette: palette,
            target: target,
            weights: weights,
            expected: scenario.expected,
            scenarioID: scenario.id,
            file: file,
            line: line
        )
    }

    private func assertSolverSelection(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights,
        expected: ParityExpectation,
        scenarioID: String,
        file: StaticString,
        line: UInt
    ) throws {
        let sourceGrids = Dictionary(uniqueKeysWithValues: weights.activeConditions.compactMap { condition in
            target.value(for: condition).map { (condition, BrightnessGrid(width: 1, height: 1, values: [$0])) }
        })
        guard sourceGrids.count == weights.activeConditions.count else { return }

        let result = try CompositionSolver().solve(palette: palette, sourceGrids: sourceGrids, weights: weights)
        XCTAssertEqual(result.colorIndex(x: 0, y: 0), expected.selectedIndex, scenarioID, file: file, line: line)
        if let expectedError = expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, scenarioID, file: file, line: line)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory.appendingPathComponent("Fixtures/Parity/v1/corpus.json")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw ParityCorpusError.missingFixture(fixture.path)
        }
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func paletteColor(_ entry: ParityEntry) -> PaletteColor {
        PaletteColor(
            id: entry.index ?? -1,
            hex: entry.hexColor,
            rgb: RGBColor(hex: entry.hexColor)!,
            responses: responses(from: entry.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func earliestMinimum(in results: [ScorerResult]) -> (index: Int?, error: Double?, tiedIndices: [Int]) {
        let scored = results.enumerated().compactMap { index, result -> (Int, Double)? in
            guard case .score(let error) = result else { return nil }
            return (index, error)
        }
        guard let minimum = scored.map(\.1).min() else { return (nil, nil, []) }
        let tiedIndices = scored.filter { $0.1 == minimum }.map(\.0)
        return (tiedIndices.first, minimum, tiedIndices)
    }
}

private enum ParityCorpusError: LocalizedError {
    case missingFixture(String)

    var errorDescription: String? {
        switch self {
        case .missingFixture(let path):
            return "Missing committed color_matching parity corpus at \(path)."
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: ParityEntry
    let palette: [ParityEntry]
    let expected: ParityExpectation
}

private struct ParityEntry: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]

    private enum CodingKeys: String, CodingKey {
        case index
        case hexColor = "hex_color"
        case channels
    }
}

private struct ParityExpectation: Decodable {
    let scores: [ParityScore]
    let selectedIndex: Int?
    let selectedHexColor: String?
    let error: Double?
    let tieBroke: Bool?
    let tiedIndices: [Int]

    private enum CodingKeys: String, CodingKey {
        case scores
        case selectedIndex = "selected_index"
        case selectedHexColor = "selected_hex_color"
        case error
        case tieBroke = "tie_broke"
        case tiedIndices = "tied_indices"
    }
}

private struct ParityScore: Decodable {
    let index: Int
    let score: Double?

    private enum CodingKeys: String, CodingKey { case index, score }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        score = try? container.decode(Double.self, forKey: .score)
    }
}

private extension ScorerResult {
    init(_ score: ParityScore) {
        self = score.score.map(ScorerResult.score) ?? .excluded
    }
}

private extension ChannelWeights {
    init(values: [String: Double]) {
        self.init(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }
}
