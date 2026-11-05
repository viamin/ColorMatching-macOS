import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the golden vectors emitted by `color_matching` issue #111.
///
/// The fixture is intentionally committed next to this test rather than fetched
/// at test time: solver compatibility must be reproducible offline and changes
/// to the upstream corpus must be reviewed explicitly.
final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesParityCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: ParityScenario) throws {
        let weights = makeWeights(scenario.weights)
        let target = makeTarget(scenario.target.channels)
        let palette = try scenario.palette.map(makePaletteColor)
        let actualScores = palette.map { score(WeightedSquaredErrorScorer().score(candidate: $0, target: target, weights: weights)) }
        XCTAssertEqual(actualScores.count, scenario.expected.scores.count)
        zip(actualScores, scenario.expected.scores).forEach { actual, expected in
            XCTAssertEqual(actual, expected.score, "candidate score mismatch for \(scenario.id) at index \(expected.index)")
        }

        let selection = bestSelection(in: actualScores)
        XCTAssertEqual(selection.index, scenario.expected.selectedIndex, "selection mismatch for corpus scenario \(scenario.id)")
        XCTAssertEqual(selection.error, scenario.expected.error, "error mismatch for corpus scenario \(scenario.id)")
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixtureURL = testDirectory.appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        let data = try Data(contentsOf: fixtureURL)
        return try JSONDecoder().decode(ParityCorpus.self, from: data)
    }

    private func makeWeights(_ values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func makeTarget(_ channels: [String: Double]) -> TargetResponseVector {
        TargetResponseVector(channels.reduce(into: [LightingCondition: Double]()) { result, entry in
            if let condition = LightingCondition(rawValue: entry.key) {
                result[condition] = entry.value
            }
        })
    }

    private func makePaletteColor(_ fixture: ParityPaletteColor) throws -> PaletteColor {
        guard let rgb = RGBColor(hex: fixture.hexColor) else {
            throw ParityFixtureError.invalidHex(fixture.hexColor)
        }
        let responses = fixture.channels.reduce(into: [LightingCondition: IlluminationResponse]()) { result, entry in
            if let condition = LightingCondition(rawValue: entry.key) {
                result[condition] = IlluminationResponse(brightness: entry.value)
            }
        }
        return PaletteColor(id: fixture.index, hex: fixture.hexColor, rgb: rgb, responses: responses)
    }

    private func score(_ result: ScorerResult) -> ParityScore {
        switch result {
        case .excluded: return .excluded
        case .score(let value): return .value(value)
        }
    }

    private func bestSelection(in scores: [ParityScore]) -> (index: Int?, error: Double?) {
        var bestIndex: Int?
        var bestError: Double?
        for (index, score) in scores.enumerated() {
            guard case .value(let error) = score else { continue }
            if bestError == nil || error < bestError! {
                bestIndex = index
                bestError = error
            }
        }
        return (bestIndex, bestError)
    }
}

private enum ParityFixtureError: Error {
    case invalidHex(String)
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityPaletteColor]
    let target: ParityTarget
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityPaletteColor: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int
}

private struct ParityTarget: Decodable {
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedIndex: Int?
}

private struct ParityExpectedScore: Decodable, Equatable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable, Equatable {
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
