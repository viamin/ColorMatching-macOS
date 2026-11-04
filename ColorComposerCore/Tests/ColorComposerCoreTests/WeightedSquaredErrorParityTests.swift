import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the golden vectors emitted by color_matching's
/// `mix parity.generate`. This is deliberately a fixture, rather than copied
/// test cases, so server and client selection semantics cannot drift silently.
final class WeightedSquaredErrorParityTests: XCTestCase {
    func testMatchesCommittedVersionOneParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: ParityScenario) throws {
        let weights = ChannelWeights(channels: scenario.weights)
        let target = TargetResponseVector(scenario.target.channelValues)
        let palette = try scenario.palette.map(makePaletteColor)
        let scorer = WeightedSquaredErrorScorer()
        let scores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(scenario.palette.compactMap(\.index), Array(scenario.palette.indices), scenario.id)
        XCTAssertEqual(scores.count, scenario.expected.scores.count, scenario.id)
        for (index, pair) in zip(scores, scenario.expected.scores).enumerated() {
            let (actual, expected) = pair
            XCTAssertEqual(expected.index, index, scenario.id)
            assert(actual, matches: expected.score, scenario: scenario.id)
        }

        let selection = earliestSelection(in: scores)
        XCTAssertEqual(selection.index, scenario.expected.selectedIndex, scenario.id)
        assert(selection.error, matches: scenario.expected.error, scenario: scenario.id)
        XCTAssertEqual(selection.index.map { palette[$0].hex }, scenario.expected.selectedHexColor, scenario.id)

        let tiedIndices = tiedIndices(in: scores, at: selection.error)
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
        XCTAssertEqual(tiedIndices.count > 1, scenario.expected.tieBroke ?? false, scenario.id)

        guard targetHasEveryActiveChannel(target, weights: weights) else { return }
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: sourceGrids(for: target, weights: weights),
            weights: weights
        )
        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
        assert(result.error(x: 0, y: 0), matches: scenario.expected.error, scenario: scenario.id)
    }

    private func loadCorpus() throws -> ParityCorpus {
        let source = URL(fileURLWithPath: #filePath)
        let fixture = source.deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makePaletteColor(_ vector: ParityVector) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: vector.hexColor), "Invalid corpus hex: \(vector.hexColor)")
        return PaletteColor(
            id: try XCTUnwrap(vector.index, "Palette colors require an index"),
            hex: vector.hexColor,
            rgb: rgb,
            responses: vector.channelValues.mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func earliestSelection(in scores: [ScorerResult]) -> (index: Int?, error: Double?) {
        scores.enumerated().reduce((index: nil, error: nil)) { best, entry in
            guard case .score(let score) = entry.element else { return best }
            guard let bestError = best.error, bestError <= score else {
                return (entry.offset, score)
            }
            return best
        }
    }

    private func tiedIndices(in scores: [ScorerResult], at error: Double?) -> [Int] {
        guard let error else { return [] }
        return scores.enumerated().compactMap { index, result in
            guard case .score(let score) = result, score == error else { return nil }
            return index
        }
    }

    private func targetHasEveryActiveChannel(_ target: TargetResponseVector, weights: ChannelWeights) -> Bool {
        weights.activeConditions.allSatisfy { target.value(for: $0) != nil }
    }

    private func sourceGrids(
        for target: TargetResponseVector,
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeConditions.map {
            ($0, BrightnessGrid(width: 1, height: 1, values: [target.value(for: $0)!]))
        })
    }

    private func assert(_ actual: ScorerResult, matches expected: ParityScore, scenario: String) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            return
        case (.score(let actual), .value(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario)
        default:
            XCTFail("\(scenario): expected \(expected), got \(actual)")
        }
    }

    private func assert(_ actual: Double?, matches expected: Double?, scenario: String) {
        switch (actual, expected) {
        case (nil, nil):
            return
        case let (actual?, expected?):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario)
        default:
            XCTFail("\(scenario): expected \(String(describing: expected)), got \(String(describing: actual))")
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let selection: String
    let missingPolicy: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: ParityVector
    let palette: [ParityVector]
    let expected: ParityExpectation
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?

    var channelValues: [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }
}

private struct ParityExpectation: Decodable {
    let error: Double?
    let scores: [ParityCandidateScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityCandidateScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable, CustomStringConvertible {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let score = try? container.decode(Double.self) {
            self = .value(score)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected score or excluded")
        }
    }

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .value(let value): return "\(value)"
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
