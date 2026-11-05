import XCTest
@testable import ColorComposerCore

final class ParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedColorMatchingParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = TargetResponseVector(responses(from: scenario.target.channels))
            let weights = channelWeights(from: scenario.weights)
            let candidates = scenario.palette.map(makePaletteColor)
            var selection: (index: Int, score: Double)?

            XCTAssertEqual(candidates.count, scenario.expected.scores.count, "scenario: \(scenario.id)")

            for (candidate, expectedScore) in zip(candidates, scenario.expected.scores) {
                XCTAssertEqual(candidate.id, expectedScore.index, "scenario: \(scenario.id)")
                let result = scorer.score(candidate: candidate, target: target, weights: weights)
                assert(result, matches: expectedScore.score, scenario: scenario.id)

                if case .score(let score) = result,
                   selection == nil || score < selection!.score {
                    selection = (candidate.id, score)
                }
            }

            XCTAssertEqual(selection?.index, scenario.expected.selectedIndex, "scenario: \(scenario.id)")
            XCTAssertEqual(selection?.score, scenario.expected.error, "scenario: \(scenario.id)")
            XCTAssertEqual(
                selection.flatMap { selected in candidates.first { $0.id == selected.index }?.hex },
                scenario.expected.selectedHexColor,
                "scenario: \(scenario.id)"
            )

            let tiedIndices = scenario.expected.scores.compactMap { score -> Int? in
                guard case .score(let value) = score.score, value == scenario.expected.error else { return nil }
                return score.index
            }
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, "scenario: \(scenario.id)")
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parity/v1/corpus.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makePaletteColor(_ vector: ParityVector) -> PaletteColor {
        PaletteColor(
            id: vector.index!,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: responses(from: vector.channels)
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        channels.reduce(into: [:]) { responses, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            responses[condition] = IlluminationResponse(brightness: entry.value)
        }
    }

    private func channelWeights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func assert(
        _ actual: ScorerResult,
        matches expected: ParityScore,
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (actual, expected) {
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "scenario: \(scenario)", file: file, line: line)
        case (.excluded, .excluded):
            break
        default:
            XCTFail("scenario: \(scenario): expected \(expected), got \(actual)", file: file, line: line)
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpectation
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ParityExpectation: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tiedIndices: [Int]
}

private struct ParityExpectedScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable, CustomStringConvertible {
    case excluded
    case score(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .score(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .score(let value): return "score(\(value))"
        }
    }
}
