import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testMatchesCommittedColorMatchingParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let weights = makeWeights(scenario.weights)
            let target = TargetResponseVector(makeResponses(scenario.target.channels))
            let palette = scenario.palette.map(makeColor)

            XCTAssertEqual(scenario.expected.scores.map(\.index), Array(palette.indices))

            let actualScores = palette.map {
                scorer.score(candidate: $0, target: target, weights: weights)
            }
            XCTAssertEqual(
                actualScores,
                scenario.expected.scores.map(\\.scorerResult),
                "score mismatch for corpus scenario \\(scenario.id)"
            )

            let selectedIndex = selectEarliestScore(from: actualScores)
            XCTAssertEqual(
                selectedIndex,
                scenario.expected.selectedIndex,
                "selection mismatch for corpus scenario \\(scenario.id)"
            )
            XCTAssertEqual(
                selectedIndex.map { palette[$0].hex },
                scenario.expected.selectedHexColor,
                "selected color mismatch for corpus scenario \\(scenario.id)"
            )

            let tiedIndices = actualScores.enumerated().compactMap { index, result -> Int? in
                guard case .score(let score) = result, score == scenario.expected.error else { return nil }
                return index
            }
            XCTAssertEqual(
                tiedIndices,
                scenario.expected.tiedIndices,
                "tie set mismatch for corpus scenario \\(scenario.id)"
            )
            XCTAssertEqual(
                scenario.expected.tieBroke,
                tiedIndices.count > 1 ? true : scenario.expected.selectedIndex == nil ? nil : false,
                "tie evidence mismatch for corpus scenario \\(scenario.id)"
            )
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makeColor(_ fixture: ParityColor) -> PaletteColor {
        PaletteColor(
            id: fixture.index!,
            hex: fixture.hexColor,
            rgb: RGBColor(hex: fixture.hexColor)!,
            responses: makeResponses(fixture.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func makeResponses(_ channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func makeWeights(_ values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0],
            red: values["red", default: 0],
            green: values["green", default: 0],
            blue: values["blue", default: 0],
            lps: values["lps", default: 0]
        )
    }

    private func selectEarliestScore(from scores: [ScorerResult]) -> Int? {
        var best: (index: Int, score: Double)?
        for (index, result) in scores.enumerated() {
            guard case .score(let score) = result else { continue }
            if best == nil || score < best!.score {
                best = (index, score)
            }
        }
        return best?.index
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityColor]
    let target: ParityColor
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityColor: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
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
    let value: Value

    enum Value: Decodable {
        case score(Double)
        case excluded

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let score = try? container.decode(Double.self) {
                self = .score(score)
            } else if try container.decode(String.self) == "excluded" {
                self = .excluded
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown parity score")
            }
        }
    }

    var scorerResult: ScorerResult {
        switch value {
        case .score(let score): return .score(score)
        case .excluded: return .excluded
        }
    }
}
