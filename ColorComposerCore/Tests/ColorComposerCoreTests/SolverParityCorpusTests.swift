import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    private let corpus = try! ParityCorpus.load()

    func testCorpusIdentifiesTheServerSolverContract() {
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
    }

    func testCorpusContainsTieAndAllExcludedCoverage() {
        XCTAssertTrue(corpus.scenarios.contains(where: { $0.expected.tieBroke == true }))
        XCTAssertTrue(corpus.scenarios.contains(where: { $0.expected.selectedIndex == nil }))
    }

    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: ParityScenario) throws {
        let palette = try scenario.palette
            .sorted { $0.index < $1.index }
            .map(makePaletteColor)
        let target = makeTarget(scenario.target)
        let weights = makeWeights(scenario.weights)
        let scorer = WeightedSquaredErrorScorer()

        for (candidate, expected) in zip(palette, scenario.expected.scores.sorted { $0.index < $1.index }) {
            XCTAssertEqual(
                scorer.score(candidate: candidate, target: target, weights: weights),
                expected.scorerResult,
                "\(scenario.id): candidate \(expected.index)",
                file: #filePath,
                line: #line
            )
        }

        let selection = select(palette, target: target, weights: weights)

        XCTAssertEqual(selection.index, scenario.expected.selectedIndex, "\(scenario.id)")
        XCTAssertEqual(selection.error, scenario.expected.error, "\(scenario.id)")
        XCTAssertEqual(selection.hexColor, scenario.expected.selectedHexColor, "\(scenario.id)")
        XCTAssertEqual(
            scenario.expected.tiedIndices,
            tiedIndices(in: palette, target: target, weights: weights, error: scenario.expected.error),
            "\(scenario.id)"
        )
        XCTAssertEqual(
            scenario.expected.tieBroke,
            scenario.expected.tiedIndices.count > 1 ? true : (scenario.expected.selectedIndex == nil ? nil : false),
            "\(scenario.id)"
        )
    }

    private func makePaletteColor(_ vector: ParityVector) throws -> PaletteColor {
        let responses = try vector.channels.reduce(into: [LightingCondition: IlluminationResponse]()) {
            result, entry in
            result[try lightingCondition(named: entry.key)] = IlluminationResponse(brightness: entry.value)
        }
        return PaletteColor(
            id: vector.index,
            hex: vector.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: vector.hexColor)),
            responses: responses
        )
    }

    private func makeTarget(_ vector: ParityVector) -> TargetResponseVector {
        TargetResponseVector(
            Dictionary(uniqueKeysWithValues: vector.channels.compactMap { name, brightness in
                guard let condition = try? lightingCondition(named: name) else { return nil }
                return (condition, brightness)
            })
        )
    }

    private func makeWeights(_ encoded: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: encoded["white", default: 0],
            red: encoded["red", default: 0],
            green: encoded["green", default: 0],
            blue: encoded["blue", default: 0],
            lps: encoded["lps", default: 0]
        )
    }

    private func tiedIndices(
        in palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights,
        error: Double?
    ) -> [Int] {
        guard let error else { return [] }
        let scorer = WeightedSquaredErrorScorer()
        return palette.enumerated().compactMap { index, candidate in
            scorer.score(candidate: candidate, target: target, weights: weights) == .score(error) ? index : nil
        }
    }

    private func select(
        _ palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> (index: Int?, error: Double?, hexColor: String?) {
        let scorer = WeightedSquaredErrorScorer()
        var selection: (index: Int?, error: Double?, hexColor: String?) = (nil, nil, nil)

        for (index, candidate) in palette.enumerated() {
            guard case .score(let error) = scorer.score(candidate: candidate, target: target, weights: weights) else {
                continue
            }
            if selection.error == nil || error < selection.error! {
                selection = (index, error, candidate.hex)
            }
        }
        return selection
    }

    private func lightingCondition(named name: String) throws -> LightingCondition {
        guard let condition = LightingCondition.all.first(where: { $0.rawValue == name }) else {
            throw ParityCorpusError.unknownLightingCondition(name)
        }
        return condition
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
    let scenarios: [ParityScenario]

    static func load() throws -> Self {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixture = testFile
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: fixture))
    }
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpected

}

private struct ParityVector: Decodable {
    let index: Int
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ParityScoreValue

    var scorerResult: ScorerResult {
        switch score {
        case .error(let error): .score(error)
        case .excluded: .excluded
        }
    }
}

private enum ParityScoreValue: Decodable {
    case error(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let error = try? container.decode(Double.self) {
            self = .error(error)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw ParityCorpusError.invalidScore
        }
    }
}

private enum ParityCorpusError: Error {
    case invalidScore
    case unknownLightingCondition(String)
}

