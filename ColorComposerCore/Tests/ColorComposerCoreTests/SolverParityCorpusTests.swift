import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedParityCorpusExactly() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: Scenario, file: StaticString = #filePath, line: UInt = #line) throws {
        let weights = ChannelWeights(values: scenario.weights)
        let target = TargetResponseVector(scenario.target.channels.lightingValues)
        let palette = try scenario.palette.map(PaletteColor.init)
        let scorer = WeightedSquaredErrorScorer()

        XCTAssertEqual(scenario.expected.scores.map(\.index), Array(palette.indices), scenario.id, file: file, line: line)

        let actualScores = try palette.map { candidate -> CorpusScore in
            switch scorer.score(candidate: candidate, target: target, weights: weights) {
            case .excluded:
                return .excluded
            case .score(let score):
                return .value(score)
            }
        }
        XCTAssertEqual(actualScores, scenario.expected.scores.map(\.score), scenario.id, file: file, line: line)

        guard Set(weights.activeConditions).isSubset(of: Set(target.brightness.keys)) else {
            XCTAssertNil(scenario.expected.selectedIndex, scenario.id, file: file, line: line)
            XCTAssertNil(scenario.expected.error, scenario.id, file: file, line: line)
            return assertTieEvidence(for: scenario, file: file, line: line)
        }

        let grids = scenario.target.channels.lightingValues.reduce(into: [LightingCondition: BrightnessGrid]()) {
            $0[$1.key] = BrightnessGrid(width: 1, height: 1, values: [$1.value])
        }
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)

        XCTAssertEqual(result.colorIndices, [scenario.expected.selectedIndex], scenario.id, file: file, line: line)
        XCTAssertEqual(result.errors, [scenario.expected.error ?? .infinity], scenario.id, file: file, line: line)
        XCTAssertEqual(
            result.colorIndices[0].map { palette[$0].hex },
            scenario.expected.selectedHexColor,
            scenario.id,
            file: file,
            line: line
        )

        assertTieEvidence(for: scenario, file: file, line: line)
    }

    private func assertTieEvidence(for scenario: Scenario, file: StaticString, line: UInt) {
        let tiedIndices = scenario.expected.error.map { expectedError in
            scenario.expected.scores.compactMap { score -> Int? in
                guard case .value(expectedError) = score.score else { return nil }
                return score.index
            }
        } ?? []
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id, file: file, line: line)
        XCTAssertEqual(
            scenario.expected.tieBroke,
            tiedIndices.isEmpty ? nil : tiedIndices.count > 1,
            scenario.id,
            file: file,
            line: line
        )
    }

    private func loadCorpus() throws -> Corpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: fixture))
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let scenarios: [Scenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case scenarios
    }
}

private struct Scenario: Decodable {
    let id: String
    let palette: [CorpusColor]
    let target: CorpusColor
    let weights: [String: Double]
    let expected: Expected
}

private struct CorpusColor: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]

    enum CodingKeys: String, CodingKey {
        case index
        case hexColor = "hex_color"
        case channels
    }
}

private struct Expected: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]

    enum CodingKeys: String, CodingKey {
        case error, scores
        case selectedHexColor = "selected_hex_color"
        case selectedIndex = "selected_index"
        case tieBroke = "tie_broke"
        case tiedIndices = "tied_indices"
    }
}

private struct ExpectedScore: Decodable {
    let index: Int
    let score: CorpusScore
}

private enum CorpusScore: Decodable, Equatable {
    case excluded
    case value(Double)

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

private extension CorpusColor {
    var lightingValues: [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }
}

private extension PaletteColor {
    init(_ corpusColor: CorpusColor) throws {
        guard let rgb = RGBColor(hex: corpusColor.hexColor) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid color hex"))
        }
        self.init(
            id: corpusColor.index ?? -1,
            hex: corpusColor.hexColor,
            rgb: rgb,
            responses: corpusColor.lightingValues.mapValues(IlluminationResponse.init(brightness:))
        )
    }
}

private extension ChannelWeights {
    init(values: [String: Double]) {
        self.init(
            white: values[LightingCondition.white.rawValue] ?? 0,
            red: values[LightingCondition.red.rawValue] ?? 0,
            green: values[LightingCondition.green.rawValue] ?? 0,
            blue: values[LightingCondition.blue.rawValue] ?? 0,
            lps: values[LightingCondition.lps.rawValue] ?? 0
        )
    }
}
