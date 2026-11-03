import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the versioned golden vectors published by `color_matching`.
///
/// The fixture is deliberately committed alongside this test rather than
/// downloaded at test time, so solver parity remains deterministic and an
/// upstream revision is reviewed as a normal source change.
final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesParityCorpusExactly() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let weights = makeWeights(scenario.weights)
            let target = TargetResponseVector(makeChannels(scenario.target.channels))
            let palette = try scenario.palette.map(makeColor)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
            let expectedScores = scenario.expected.scores.map(\.score)

            XCTAssertEqual(scenario.expected.scores.map(\.index), Array(palette.indices), "invalid score table for corpus scenario \(scenario.id)")
            XCTAssertEqual(actualScores, expectedScores, "score mismatch for corpus scenario \(scenario.id)")

            let selected = earliestLowestScore(in: actualScores)
            XCTAssertEqual(selected.index, scenario.expected.selectedIndex, "selection mismatch for corpus scenario \(scenario.id)")
            XCTAssertEqual(selected.error, scenario.expected.error, "selection error mismatch for corpus scenario \(scenario.id)")

            let tiedIndices = tiedIndices(in: actualScores, at: selected.error)
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, "tie set mismatch for corpus scenario \(scenario.id)")
            XCTAssertEqual(
                tiedIndices.count > 1 ? true : nil,
                scenario.expected.tieBroke,
                "tie-break evidence mismatch for corpus scenario \(scenario.id)"
            )
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parity-v1-corpus.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
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

    private func makeChannels(_ values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func makeColor(_ entry: ParityCorpus.Entry) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: entry.hexColor), "invalid corpus color \(entry.hexColor)")
        return PaletteColor(
            id: entry.index ?? -1,
            hex: entry.hexColor,
            rgb: rgb,
            responses: makeChannels(entry.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func earliestLowestScore(in scores: [ScorerResult]) -> (index: Int?, error: Double?) {
        var selectedIndex: Int?
        var selectedError: Double?

        for (index, score) in scores.enumerated() {
            guard case .score(let error) = score else { continue }
            if selectedError == nil || error < selectedError! {
                selectedIndex = index
                selectedError = error
            }
        }
        return (selectedIndex, selectedError)
    }

    private func tiedIndices(in scores: [ScorerResult], at error: Double?) -> [Int] {
        guard let expectedError = error else { return [] }
        return scores.enumerated().compactMap { index, score in
            guard case .score(let scoreError) = score else { return nil }
            return scoreError == expectedError ? index : nil
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let selection: String
    let missingPolicy: String
    let scenarios: [Scenario]

    struct Scenario: Decodable {
        let id: String
        let weights: [String: Double]
        let target: Entry
        let palette: [Entry]
        let expected: Expected
    }

    struct Entry: Decodable {
        let index: Int?
        let hexColor: String
        let channels: [String: Double]
    }

    struct Expected: Decodable {
        let error: Double?
        let scores: [ExpectedScore]
        let selectedIndex: Int?
        let tieBroke: Bool?
        let tiedIndices: [Int]
    }

    struct ExpectedScore: Decodable {
        let index: Int
        let score: ScorerResult

        enum CodingKeys: String, CodingKey { case index, score }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            index = try container.decode(Int.self, forKey: .index)
            if let value = try? container.decode(Double.self, forKey: .score) {
                score = .score(value)
            } else {
                let exclusion = try container.decode(String.self, forKey: .score)
                guard exclusion == "excluded" else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .score,
                        in: container,
                        debugDescription: "Expected a numeric score or the excluded marker."
                    )
                }
                score = .excluded
            }
        }
    }
}
