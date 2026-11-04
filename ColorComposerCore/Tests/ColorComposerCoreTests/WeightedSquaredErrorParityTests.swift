import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testReplaysCommittedV1CorpusExactly() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertFalse(corpus.scenarios.isEmpty)

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: Scenario, file: StaticString = #filePath, line: UInt = #line) throws {
        let scorer = WeightedSquaredErrorScorer()
        let weights = ChannelWeights(channels: scenario.weights)
        let target = TargetResponseVector(channels: scenario.target.channels)
        let palette = try scenario.palette.map { try PaletteColor(entry: $0) }
        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(actualScores, scenario.expected.scores.map(ScorerResult.init), scenario.id, file: file, line: line)

        let selectedIndex = actualScores.firstIndex { $0 == .score(scenario.expected.error ?? .infinity) }
        XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, scenario.id, file: file, line: line)
        let tiedIndices = actualScores.enumerated().compactMap { index, score in
            score == .score(scenario.expected.error ?? .infinity) ? index : nil
        }
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id, file: file, line: line)
        if scenario.expected.selectedIndex == nil {
            XCTAssertNil(scenario.expected.tieBroke, scenario.id, file: file, line: line)
        } else {
            XCTAssertEqual(scenario.expected.tieBroke, tiedIndices.count > 1, scenario.id, file: file, line: line)
        }

        guard let selectedIndex, let expectedError = scenario.expected.error else {
            XCTAssertNil(scenario.expected.selectedHexColor, scenario.id, file: file, line: line)
            return
        }

        XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor, scenario.id, file: file, line: line)
        XCTAssertEqual(actualScores[selectedIndex], .score(expectedError), scenario.id, file: file, line: line)

        if let sourceGrids = sourceGrids(for: target, weights: weights) {
            let result = try CompositionSolver().solve(palette: palette, sourceGrids: sourceGrids, weights: weights)
            XCTAssertEqual(result.colorIndex(x: 0, y: 0), selectedIndex, scenario.id, file: file, line: line)
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, scenario.id, file: file, line: line)
        }
    }

    private func loadCorpus() throws -> Corpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixture = testFile.deletingLastPathComponent().appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: fixture))
    }

    private func sourceGrids(for target: TargetResponseVector, weights: ChannelWeights) -> [LightingCondition: BrightnessGrid]? {
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for condition in weights.activeConditions {
            guard let brightness = target.value(for: condition) else { return nil }
            grids[condition] = BrightnessGrid(width: 1, height: 1, values: [brightness])
        }
        return grids
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: VectorEntry
    let palette: [VectorEntry]
    let expected: Expected
}

private struct VectorEntry: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct Expected: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private enum ExpectedScore: Decodable {
    case score(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let score = try? container.decode(Double.self) {
            self = .score(score)
        } else {
            guard try container.decode(String.self) == "excluded" else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a numeric score or excluded")
            }
            self = .excluded
        }
    }
}

private extension ScorerResult {
    init(_ expected: ExpectedScore) {
        switch expected {
        case .score(let value): self = .score(value)
        case .excluded: self = .excluded
        }
    }
}

private extension ChannelWeights {
    init(channels: [String: Double]) {
        self.init(
            white: channels["white"] ?? 0,
            red: channels["red"] ?? 0,
            green: channels["green"] ?? 0,
            blue: channels["blue"] ?? 0,
            lps: channels["lps"] ?? 0
        )
    }
}

private extension TargetResponseVector {
    init(channels: [String: Double]) {
        self.init(Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, brightness) }
        }))
    }
}

private extension PaletteColor {
    init(entry: VectorEntry) throws {
        guard let rgb = RGBColor(hex: entry.hexColor) else {
            throw NSError(domain: "WeightedSquaredErrorParityTests", code: 1)
        }
        let responses = Dictionary(uniqueKeysWithValues: entry.channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, IlluminationResponse(brightness: brightness)) }
        })
        self.init(id: entry.index ?? -1, hex: entry.hexColor, rgb: rgb, responses: responses)
    }
}
