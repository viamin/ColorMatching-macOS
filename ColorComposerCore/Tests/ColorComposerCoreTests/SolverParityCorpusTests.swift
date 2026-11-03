import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.scenarios.count, 12, "The committed fixture must contain every v1 upstream scenario")
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: Scenario, file: StaticString = #filePath, line: UInt = #line) throws {
        let weights = ChannelWeights(values: scenario.weights)
        let target = TargetResponseVector(scenario.target.conditions)
        let palette = try scenario.palette.map(PaletteColor.init)
        let scorer = WeightedSquaredErrorScorer()

        for (candidate, expected) in zip(palette, scenario.expected.scores) {
            switch (scorer.score(candidate: candidate, target: target, weights: weights), expected) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .score(let value)):
                XCTAssertEqual(actual, value, accuracy: 1e-12, "\(scenario.id): \(candidate.hex)", file: file, line: line)
            default:
                XCTFail("\(scenario.id): unexpected exclusion result for \(candidate.hex)", file: file, line: line)
            }
        }

        guard let selectedIndex = scenario.expected.selectedIndex else { return }
        let grids = Dictionary(uniqueKeysWithValues: target.brightness.map { condition, value in
            (condition, BrightnessGrid(width: 1, height: 1, values: [value]))
        })
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), selectedIndex, scenario.id, file: file, line: line)
        XCTAssertEqual(result.palette[selectedIndex].hex, scenario.expected.selectedHexColor, scenario.id, file: file, line: line)
        XCTAssertEqual(result.error(x: 0, y: 0), scenario.expected.error, accuracy: 1e-12, file: file, line: line)
    }

    private func loadCorpus() throws -> Corpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }
}

private extension ChannelWeights {
    init(values: [String: Double]) {
        self.init(
            white: values["white", default: 0], red: values["red", default: 0],
            green: values["green", default: 0], blue: values["blue", default: 0],
            lps: values["lps", default: 0]
        )
    }
}

private extension PaletteColor {
    init(_ fixture: PaletteFixture) throws {
        let responses = try fixture.channels.reduce(into: [LightingCondition: IlluminationResponse]()) { result, entry in
            result[try LightingCondition(rawValue: entry.key).unwrap()] = IlluminationResponse(brightness: entry.value)
        }
        self.init(id: fixture.index, hex: fixture.hex, rgb: try RGBColor(hex: fixture.hex).unwrap(), responses: responses)
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let self else { throw FixtureError.invalidLightingCondition }
        return self
    }
}

private enum FixtureError: Error { case invalidLightingCondition }

private struct Corpus: Decodable {
    let sourceSHA: String
    let algorithmVersion: Int
    let selection: String
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: VectorFixture
    let palette: [PaletteFixture]
    let expected: Expected
}

private struct VectorFixture: Decodable {
    let channels: [String: Double]
    var conditions: [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }
}

private struct PaletteFixture: Decodable {
    let index: Int
    let hex: String
    let channels: [String: Double]
}

private struct Expected: Decodable {
    let selectedIndex: Int?
    let selectedHexColor: String?
    let error: Double?
    let scores: [Score]
}

private enum Score: Decodable {
    case score(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) { self = .score(value) }
        else if try container.decode(String.self) == "excluded" { self = .excluded }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected score or excluded") }
    }
}
