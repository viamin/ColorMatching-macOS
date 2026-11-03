import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testMatchesCommittedColorMatchingParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let target = TargetResponseVector(responses(from: scenario.target.channels))
        let weights = weights(from: scenario.weights)
        let palette = try scenario.palette.map(makeColor)
        let actual = palette.enumerated().map { index, color in
            CandidateScore(index: index, result: scorer.score(candidate: color, target: target, weights: weights))
        }

        XCTAssertEqual(actual.map(\.index), scenario.expected.scores.map(\.index), scenario.id)
        for (actualScore, expectedScore) in zip(actual, scenario.expected.scores) {
            assert(actualScore.result, matches: expectedScore.score, scenario: scenario.id)
        }

        let ranked = actual.compactMap { candidate -> (index: Int, score: Double)? in
            guard case .score(let score) = candidate.result else { return nil }
            return (candidate.index, score)
        }
        let best = ranked.min { $0.score < $1.score }
        XCTAssertEqual(best?.index, scenario.expected.selectedIndex, scenario.id)
        switch (best?.score, scenario.expected.error) {
        case let (actual?, expected?):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario.id)
        case (nil, nil):
            break
        default:
            XCTFail("\(scenario.id): expected error \(String(describing: scenario.expected.error)), got \(String(describing: best?.score))")
        }
        XCTAssertEqual(best.map { palette[$0.index].hex }, scenario.expected.selectedHexColor, scenario.id)

        let ties = ranked.filter { $0.score == best?.score }.map(\.index)
        XCTAssertEqual(ties, scenario.expected.tiedIndices, scenario.id)
        XCTAssertEqual(ties.count > 1 ? true : false, scenario.expected.tieBroke ?? false, scenario.id)
    }

    private func assert(_ actual: ScorerResult, matches expected: CorpusScore, scenario: String) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario)
        default:
            XCTFail("\(scenario): expected \(expected), got \(actual)")
        }
    }

    private func makeColor(_ fixture: CorpusColor) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: fixture.hexColor), "Invalid fixture color \(fixture.hexColor)")
        return PaletteColor(
            id: try XCTUnwrap(fixture.index, "Palette fixture is missing its index"),
            hex: fixture.hexColor,
            rgb: rgb,
            responses: responses(from: fixture.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        channels.reduce(into: [:]) { result, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            result[condition] = entry.value
        }
    }

    private func weights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0],
            red: values["red", default: 0],
            green: values["green", default: 0],
            blue: values["blue", default: 0],
            lps: values["lps", default: 0]
        )
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
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
    let palette: [CorpusColor]
    let target: CorpusColor
    let weights: [String: Double]
    let expected: ExpectedSelection
}

private struct CorpusColor: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ExpectedSelection: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ExpectedScore: Decodable {
    let index: Int
    let score: CorpusScore
}

private enum CorpusScore: Decodable, CustomStringConvertible {
    case excluded
    case score(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .score(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown corpus score")
        }
    }

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .score(let value): return "\(value)"
        }
    }
}

private struct CandidateScore {
    let index: Int
    let result: ScorerResult
}
