import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the immutable `color_matching` parity corpus committed in
/// `Fixtures/solver-parity-v1.json` (upstream commit a82aec5). Keep this test
/// independent of network access: fixture refreshes are a reviewed source
/// update, not a test-time download.
final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesVersionOneCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let palette = try scenario.palette.map(makeColor)
            let target = try makeTarget(scenario.target.channels)
            let weights = try makeWeights(scenario.weights)
            let actualScores = palette.map {
                scorer.score(candidate: $0, target: target, weights: weights)
            }

            XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
            for (position, expected) in scenario.expected.scores.enumerated() {
                let actual = actualScores[position]
                XCTAssertEqual(expected.index, position, scenario.id)
                assert(actual, equals: expected.score, scenario: scenario.id)
            }

            let selection = selectEarliestLowestScore(from: actualScores)
            XCTAssertEqual(selection.index, scenario.expected.selectedIndex, scenario.id)
            assert(selection.score, equals: scenario.expected.error, scenario: scenario.id)
            XCTAssertEqual(selection.index.map { palette[$0].hex }, scenario.expected.selectedHexColor, scenario.id)

            let tiedIndices = actualScores.enumerated().compactMap { index, result -> Int? in
                guard case .score(let score) = result, score == selection.score else { return nil }
                return index
            }
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)

            // The production solver builds complete targets from source grids.
            // A corpus case with a missing target response is scorer-only by
            // definition; every other case must agree through the fast path too.
            if weights.activeConditions.allSatisfy({ target.value(for: $0) != nil }) {
                let result = try CompositionSolver().solve(
                    palette: palette,
                    sourceGrids: sourceGrids(for: target, active: weights.activeConditions),
                    weights: weights
                )
                XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
                XCTAssertEqual(result.error(x: 0, y: 0), scenario.expected.error ?? .infinity, accuracy: 1e-12, scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixture = testFile.deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makeColor(_ fixture: ParityPaletteColor) throws -> PaletteColor {
        PaletteColor(
            id: fixture.index,
            hex: fixture.hexColor,
            rgb: try rgb(hex: fixture.hexColor),
            responses: try responses(from: fixture.channels)
        )
    }

    private func makeTarget(_ channels: [String: Double]) throws -> TargetResponseVector {
        TargetResponseVector(try channelValues(from: channels))
    }

    private func makeWeights(_ weights: [String: Double]) throws -> ChannelWeights {
        let values = try channelValues(from: weights)
        return ChannelWeights(
            white: values[.white] ?? 0,
            red: values[.red] ?? 0,
            green: values[.green] ?? 0,
            blue: values[.blue] ?? 0,
            lps: values[.lps] ?? 0
        )
    }

    private func responses(from channels: [String: Double]) throws -> [LightingCondition: IlluminationResponse] {
        try channelValues(from: channels).mapValues(IlluminationResponse.init(brightness:))
    }

    private func channelValues(from values: [String: Double]) throws -> [LightingCondition: Double] {
        var channels: [LightingCondition: Double] = [:]
        for (name, value) in values {
            // The backend may add weights for lights this client does not yet
            // model; the version-one corpus requires them to be ignored.
            guard let condition = LightingCondition(rawValue: name) else { continue }
            channels[condition] = value
        }
        return channels
    }

    private func rgb(hex: String) throws -> RGBColor {
        guard let value = RGBColor(hex: hex) else {
            throw ParityCorpusError.invalidHex(hex)
        }
        return value
    }

    private func sourceGrids(
        for target: TargetResponseVector,
        active: [LightingCondition]
    ) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: active.map {
            ($0, BrightnessGrid(width: 1, height: 1, values: [target.value(for: $0)!]))
        })
    }

    private func selectEarliestLowestScore(from scores: [ScorerResult]) -> (index: Int?, score: Double?) {
        var selection: (index: Int?, score: Double?) = (nil, nil)
        for (index, result) in scores.enumerated() {
            guard case .score(let score) = result else { continue }
            if selection.score == nil || score < selection.score! {
                selection = (index, score)
            }
        }
        return selection
    }

    private func assert(_ actual: ScorerResult, equals expected: ParityScore, scenario: String) {
        switch (actual, expected) {
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario)
        case (.excluded, .excluded):
            break
        default:
            XCTFail("Unexpected score for \(scenario): \(actual)")
        }
    }

    private func assert(_ actual: Double?, equals expected: Double?, scenario: String) {
        switch (actual, expected) {
        case let (.some(actual), .some(expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario)
        case (.none, .none):
            break
        default:
            XCTFail("Unexpected selected error for \(scenario): \(String(describing: actual))")
        }
    }
}

private enum ParityCorpusError: Error {
    case invalidHex(String)
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
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
    let index: Int
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityTarget: Decodable {
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tiedIndices: [Int]
}

private struct ParityExpectedScore: Decodable, Equatable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable, Equatable {
    case score(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let score = try? container.decode(Double.self) {
            self = .score(score)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected score or excluded")
        }
    }
}
