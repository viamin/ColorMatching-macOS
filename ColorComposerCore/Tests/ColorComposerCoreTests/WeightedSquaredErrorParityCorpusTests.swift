import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the committed `color_matching` golden vectors. The fixture is the
/// cross-language contract for scoring, exclusions, and earliest-wins ties.
final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testCorpusMetadataDeclaresTheSupportedSolverContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
        XCTAssertFalse(corpus.scenarios.isEmpty)
    }

    func testPackageDeclaresTheOpenAPIClientRuntimeAndGenerator() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: package)

        XCTAssertTrue(manifest.contains("swift-openapi-runtime"))
        XCTAssertTrue(manifest.contains("swift-openapi-generator"))
    }

    func testWeightedSquaredErrorScorerMatchesEveryParityScenarioExactly() throws {
        let scorer = WeightedSquaredErrorScorer()

        for scenario in try loadCorpus().scenarios {
            let target = target(from: scenario.target)
            let weights = weights(from: scenario.weights)
            let actualScores = scenario.palette.map { scorer.score(candidate: color(from: $0), target: target, weights: weights) }

            XCTAssertEqual(scenario.expected.scores.map(\.index), Array(scenario.palette.indices), scenario.id)
            XCTAssertEqual(actualScores, scenario.expected.scores.map { ScorerResult($0.score) }, scenario.id)
            assertSelection(actualScores, scenario: scenario)
        }
    }

    private func assertSelection(_ scores: [ScorerResult], scenario: ParityScenario, file: StaticString = #filePath, line: UInt = #line) {
        let ranked = scores.enumerated().compactMap { index, result -> (Int, Double)? in
            guard case .score(let error) = result else { return nil }
            return (index, error)
        }
        let winner = ranked.min { lhs, rhs in lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 < rhs.1 }

        XCTAssertEqual(winner?.0, scenario.expected.selectedIndex, scenario.id, file: file, line: line)
        XCTAssertEqual(winner?.1, scenario.expected.error, scenario.id, file: file, line: line)

        let tiedIndices = winner.map { winner in
            ranked.filter { $0.1 == winner.1 }.map(\.0)
        } ?? []
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id, file: file, line: line)
        XCTAssertEqual(tiedIndices.count > 1, scenario.expected.tieBroke ?? false, scenario.id, file: file, line: line)

        if let index = winner?.0 {
            XCTAssertEqual(scenario.palette[index].hexColor, scenario.expected.selectedHexColor, scenario.id, file: file, line: line)
        } else {
            XCTAssertNil(scenario.expected.selectedHexColor, scenario.id, file: file, line: line)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: file))
    }

    private func color(from vector: ParityVector) -> PaletteColor {
        PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: Dictionary(uniqueKeysWithValues: vector.channels.compactMap { key, brightness in
                LightingCondition(rawValue: key).map { ($0, IlluminationResponse(brightness: brightness)) }
            })
        )
    }

    private func target(from vector: ParityVector) -> TargetResponseVector {
        TargetResponseVector(Dictionary(uniqueKeysWithValues: vector.channels.compactMap { key, brightness in
            LightingCondition(rawValue: key).map { ($0, brightness) }
        }))
    }

    private func weights(from encoded: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: encoded["white"] ?? 0,
            red: encoded["red"] ?? 0,
            green: encoded["green"] ?? 0,
            blue: encoded["blue"] ?? 0,
            lps: encoded["lps"] ?? 0
        )
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: ParityVector
    let palette: [ParityVector]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [IndexedParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct IndexedParityScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable {
    case score(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let score = try? value.decode(Double.self) {
            self = .score(score)
        } else {
            let string = try value.decode(String.self)
            guard string == "excluded" else {
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unknown parity score: \(string)")
            }
            self = .excluded
        }
    }
}

private extension ScorerResult {
    init(_ parityScore: ParityScore) {
        switch parityScore {
        case .score(let value): self = .score(value)
        case .excluded: self = .excluded
        }
    }
}
