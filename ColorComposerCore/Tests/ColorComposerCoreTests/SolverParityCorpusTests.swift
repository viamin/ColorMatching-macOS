import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testCommittedCorpusReplaysScoresSelectionsAndTies() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let corpus = try decoder.decode(Corpus.self, from: try Data(contentsOf: corpusURL))
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: Scenario) throws {
        let weights = ChannelWeights(channels: scenario.weights)
        let target = TargetResponseVector(scenario.target.channels.lightingValues)
        let palette = try scenario.palette.sorted { $0.index < $1.index }.map { vector in
            try PaletteColor(vector: vector)
        }
        let scores = palette.map { WeightedSquaredErrorScorer().score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(scores, scenario.expected.scores.sorted { $0.index < $1.index }.map(ScorerResult.init), scenario.id)

        if weights.activeConditions.allSatisfy({ target.value(for: $0) != nil }) {
            let grids = Dictionary(uniqueKeysWithValues: target.brightness.map { condition, value in
                (condition, BrightnessGrid(width: 1, height: 1, values: [value]))
            })
            let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)

            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(result.error(x: 0, y: 0), scenario.expected.error ?? .infinity, scenario.id)
            if let selectedIndex = result.colorIndex(x: 0, y: 0) {
                guard let expectedHex = scenario.expected.selectedHexColor else {
                    return XCTFail("\(scenario.id): selection is missing its expected hex color")
                }
                XCTAssertEqual(palette[selectedIndex].hex, expectedHex, scenario.id)
            } else {
                XCTAssertNil(scenario.expected.selectedHexColor, scenario.id)
            }
        } else {
            XCTAssertNil(scenario.expected.selectedIndex, scenario.id)
            XCTAssertNil(scenario.expected.error, scenario.id)
        }

        let tiedIndices = scores.enumerated().compactMap { index, result -> Int? in
            result == .score(scenario.expected.error ?? .infinity) ? index : nil
        }
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
        if scenario.expected.selectedIndex == nil {
            XCTAssertNil(scenario.expected.tieBroke, scenario.id)
        } else {
            XCTAssertEqual(scenario.expected.tieBroke, tiedIndices.count > 1, scenario.id)
        }
    }

    private var corpusURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let palette: [Vector]
    let target: Vector
    let weights: [String: Double]
    let expected: Expected
}

private struct Vector: Decodable {
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

private struct ExpectedScore: Decodable {
    let index: Int
    let score: Score
}

private enum Score: Decodable {
    case value(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) { self = .value(value) }
        else if try container.decode(String.self) == "excluded" { self = .excluded }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown corpus score") }
    }
}

private extension ScorerResult {
    init(_ score: ExpectedScore) {
        switch score.score {
        case .value(let value): self = .score(value)
        case .excluded: self = .excluded
        }
    }
}

private extension PaletteColor {
    init(vector: Vector) throws {
        guard let rgb = RGBColor(hex: vector.hexColor) else {
            throw NSError(domain: "SolverParityCorpus", code: 1)
        }
        self.init(
            id: vector.index ?? 0,
            hex: vector.hexColor,
            rgb: rgb,
            responses: vector.channels.lightingValues.mapValues(IlluminationResponse.init(brightness:))
        )
    }
}

private extension Dictionary where Key == String, Value == Double {
    var lightingValues: [LightingCondition: Double] {
        compactMap { key, value in LightingCondition(rawValue: key).map { ($0, value) } }
            .reduce(into: [:]) { $0[$1.0] = $1.1 }
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
