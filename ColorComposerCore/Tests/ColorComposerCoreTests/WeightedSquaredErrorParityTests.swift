import Foundation
import XCTest
@testable import ColorComposerCore

/// Golden-vector coverage for the server's `ColorMatching.WeightedSquaredError`.
///
/// The fixture is copied verbatim from `viamin/color_matching` so a solver
/// behavior change is visible as a contract failure rather than a hand-written
/// example drifting independently.
final class WeightedSquaredErrorParityTests: XCTestCase {
    func testMatchesVersionOneParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario, file: StaticString = #filePath, line: UInt = #line) throws {
        let scorer = WeightedSquaredErrorScorer()
        let weights = weights(from: scenario.weights)
        let target = TargetResponseVector(responses(from: scenario.target.channels))
        let candidates = try scenario.palette.map(makeCandidate)
        let actualScores = candidates.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id, file: file, line: line)
        for expected in scenario.expected.scores {
            let actual = try XCTUnwrap(actualScores[safe: expected.index], "Missing candidate \(expected.index) in \(scenario.id)")
            switch (actual, expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .value(let expected)):
                XCTAssertEqual(actual, expected, scenario.id, file: file, line: line)
            default:
                XCTFail("Score mismatch for candidate \(expected.index) in \(scenario.id): expected \(expected.score)", file: file, line: line)
            }
        }

        let ranked = actualScores.enumerated().compactMap { index, result -> (Int, Double)? in
            guard case .score(let score) = result else { return nil }
            return (index, score)
        }
        let best = ranked.min { $0.1 < $1.1 }

        XCTAssertEqual(best?.0, scenario.expected.selectedIndex, scenario.id, file: file, line: line)
        XCTAssertEqual(best?.1, scenario.expected.error, scenario.id, file: file, line: line)
        XCTAssertEqual(best.map { candidates[$0.0].hex }, scenario.expected.selectedHexColor, scenario.id, file: file, line: line)
        XCTAssertEqual(
            ranked.filter { $0.1 == scenario.expected.error }.map(\.0),
            scenario.expected.tiedIndices,
            scenario.id,
            file: file,
            line: line
        )
        XCTAssertEqual(scenario.expected.tiedIndices.count > 1, scenario.expected.tieBroke, scenario.id, file: file, line: line)
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makeCandidate(_ vector: ParityVector) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: vector.hexColor), "Invalid corpus color: \(vector.hexColor)")
        return PaletteColor(
            id: vector.index ?? 0,
            hex: vector.hexColor,
            rgb: rgb,
            responses: responses(from: vector.channels)
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, IlluminationResponse(brightness: brightness)) }
        })
    }

    private func weights(from channels: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: channels["white", default: 0],
            red: channels["red", default: 0],
            green: channels["green", default: 0],
            blue: channels["blue", default: 0],
            lps: channels["lps", default: 0]
        )
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ParityExpectedScore
}

private enum ParityExpectedScore: Decodable, CustomStringConvertible {
    case excluded
    case value(Double)

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .value(let value): return String(value)
        }
    }

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

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
