import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testReplaysServerAuthoredParityCorpus() throws {
        let corpus = try decodeCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    func testPackageDeclaresGeneratedOpenAPIClientDependencies() throws {
        let package = try String(contentsOf: packageURL(), encoding: .utf8)
        XCTAssertTrue(package.contains("swift-openapi-generator"))
        XCTAssertTrue(package.contains("swift-openapi-runtime"))
    }

    private func assertScenario(_ scenario: ParityScenario) throws {
        let weights = ChannelWeights(channels: scenario.weights)
        let target = TargetResponseVector(channels: scenario.target.channels)
        let palette = try scenario.palette.map(makeColor)
        let scorer = WeightedSquaredErrorScorer()

        for (candidate, expected) in zip(palette, scenario.expected.scores) {
            XCTAssertEqual(candidate.id, expected.index, scenario.id)
            switch (scorer.score(candidate: candidate, target: target, weights: weights), expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .value(let expected)):
                XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario.id)
            default:
                XCTFail("\(scenario.id): score did not match corpus")
            }
        }

        guard weights.activeConditions.allSatisfy({ target.value(for: $0) != nil }) else {
            XCTAssertNil(scenario.expected.selectedIndex, scenario.id)
            return
        }

        let sourceGrids = Dictionary(uniqueKeysWithValues: weights.activeConditions.map {
            ($0, BrightnessGrid(width: 1, height: 1, fill: target.value(for: $0)!))
        })
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: sourceGrids,
            weights: weights
        )

        XCTAssertEqual(result.colorIndices[0], scenario.expected.selectedIndex, scenario.id)
        if let expectedError = scenario.expected.error {
            XCTAssertEqual(result.errors[0], expectedError, accuracy: 1e-12, scenario.id)
        } else {
            XCTAssertEqual(result.errors[0], .infinity, scenario.id)
        }
        XCTAssertEqual(
            tiedIndices(in: scenario.expected.scores, at: scenario.expected.error),
            scenario.expected.tiedIndices,
            scenario.id
        )
    }

    private func decodeCorpus() throws -> ParityCorpus {
        let data = try Data(contentsOf: corpusURL())
        return try JSONDecoder().decode(ParityCorpus.self, from: data)
    }

    private func makeColor(_ entry: ParityEntry) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: entry.hexColor))
        let responses = Dictionary(uniqueKeysWithValues: entry.channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, IlluminationResponse(brightness: brightness)) }
        })
        return PaletteColor(id: try XCTUnwrap(entry.index), hex: entry.hexColor, rgb: rgb, responses: responses)
    }

    private func tiedIndices(in scores: [ParityScore], at error: Double?) -> [Int] {
        guard let error else { return [] }
        return scores.compactMap { score in
            guard case .value(let scoreError) = score.score, scoreError == error else { return nil }
            return score.index
        }
    }

    private func corpusURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parity-v1.json")
    }

    private func packageURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
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

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: ParityEntry
    let palette: [ParityEntry]
    let expected: ParityExpected
}

private struct ParityEntry: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let selectedIndex: Int?
    let scores: [ParityScore]
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ExpectedScore
}

private enum ExpectedScore: Decodable {
    case value(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else {
            XCTAssertEqual(try container.decode(String.self), "excluded")
            self = .excluded
        }
    }
}
