import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the golden vectors emitted by `viamin/color_matching`.
///
/// Keep the fixture byte-for-byte in sync with the upstream v1 corpus. The
/// test deliberately exercises both the scorer (including excluded candidates)
/// and the solver (including earliest-wins selection).
final class SolverParityCorpusTests: XCTestCase {
    func testCorpusMatchesWeightedSquaredErrorScorerAndSolver() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: Scenario, file: StaticString = #filePath, line: UInt = #line) throws {
        let weights = ChannelWeights(channels: scenario.weights)
        let target = TargetResponseVector(scenario.target.channels)
        let palette = try scenario.palette.map { try makePaletteColor($0) }
        let scorer = WeightedSquaredErrorScorer()

        XCTAssertEqual(
            try scenario.palette.map { try XCTUnwrap($0.index) },
            Array(scenario.palette.indices),
            scenario.id,
            file: file,
            line: line
        )
        XCTAssertEqual(scenario.expected.scores.count, palette.count, scenario.id, file: file, line: line)

        for expected in scenario.expected.scores {
            let actual = scorer.score(candidate: palette[expected.index], target: target, weights: weights)
            switch (actual, expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .number(let expected)):
                XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario.id, file: file, line: line)
            default:
                XCTFail("\(scenario.id): candidate \(expected.index) score differs from corpus", file: file, line: line)
            }
        }

        guard let selectedIndex = scenario.expected.selectedIndex else {
            XCTAssertTrue(scenario.expected.scores.allSatisfy { $0.score == .excluded }, scenario.id, file: file, line: line)
            return
        }

        let grids = Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [scenario.target.channels[condition]!]))
        })
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), selectedIndex, scenario.id, file: file, line: line)
        XCTAssertEqual(result.error(x: 0, y: 0), scenario.expected.error!, accuracy: 1e-12, scenario.id, file: file, line: line)
        XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor, scenario.id, file: file, line: line)
        XCTAssertEqual(
            scenario.expected.tiedIndices.first,
            selectedIndex,
            "\(scenario.id): ties must keep the earliest candidate",
            file: file,
            line: line
        )
    }

    private func makePaletteColor(_ fixture: FixtureColor) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: fixture.hexColor), "Invalid fixture hex color \(fixture.hexColor)")
        return PaletteColor(
            id: try XCTUnwrap(fixture.index, "Palette fixture color requires an index"),
            hex: fixture.hexColor,
            rgb: rgb,
            responses: fixture.channels.mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func loadCorpus() throws -> Corpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Corpus.self, from: Data(contentsOf: fixture))
    }
}

private extension ChannelWeights {
    init(channels: [LightingCondition: Double]) {
        self.init(
            white: channels[.white] ?? 0,
            red: channels[.red] ?? 0,
            green: channels[.green] ?? 0,
            blue: channels[.blue] ?? 0,
            lps: channels[.lps] ?? 0
        )
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
    let palette: [FixtureColor]
    let target: FixtureColor
    let weights: [LightingCondition: Double]
    let expected: Expected
}

private struct FixtureColor: Decodable {
    let channels: [LightingCondition: Double]
    let hexColor: String
    let index: Int?
}

private struct Expected: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tiedIndices: [Int]
}

private struct ExpectedScore: Decodable {
    let index: Int
    let score: CorpusScore
}

private enum CorpusScore: Decodable, Equatable {
    case excluded
    case number(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected score or excluded")
        }
    }
}
