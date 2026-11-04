import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testSelectionsMatchColorMatchingParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = TargetResponseVector(channelValues(scenario.target))
            let weights = makeWeights(scenario.weights)
            let candidates = try scenario.palette.map(makeCandidate)
            let scored = candidates.map { candidate in
                (candidate.index, scorer.score(candidate: candidate.color, target: target, weights: weights))
            }

            XCTAssertEqual(
                selectEarliestLowest(scored),
                scenario.expected.selectedIndex,
                "scenario \(scenario.id): selected palette index"
            )
            assertEqualScores(
                lowestScore(scored),
                scenario.expected.error,
                scenarioID: scenario.id
            )
            XCTAssertEqual(
                tiedIndices(scored),
                scenario.expected.tiedIndices,
                "scenario \(scenario.id): tied palette indices"
            )
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makeCandidate(_ fixture: CandidateFixture) throws -> IndexedCandidate {
        let rgb = try XCTUnwrap(RGBColor(hex: fixture.hexColor), "Invalid fixture color \(fixture.hexColor)")
        let responses = channelValues(fixture.channels).mapValues { IlluminationResponse(brightness: $0) }
        return IndexedCandidate(
            index: fixture.index,
            color: PaletteColor(id: fixture.index, hex: fixture.hexColor, rgb: rgb, responses: responses)
        )
    }

    private func channelValues(_ values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
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

    private func selectEarliestLowest(_ scored: [(Int, ScorerResult)]) -> Int? {
        var selection: (index: Int, score: Double)?
        for (index, result) in scored {
            guard case .score(let score) = result else { continue }
            if let selection, score < selection.score {
                selection = (index, score)
            } else if selection == nil {
                selection = (index, score)
            }
        }
        return selection?.index
    }

    private func lowestScore(_ scored: [(Int, ScorerResult)]) -> Double? {
        scored.compactMap { _, result -> Double? in
            guard case .score(let score) = result else { return nil }
            return score
        }.min()
    }

    private func tiedIndices(_ scored: [(Int, ScorerResult)]) -> [Int] {
        guard let lowest = lowestScore(scored) else { return [] }
        return scored.compactMap { index, result in
            guard case .score(let score) = result, score == lowest else { return nil }
            return index
        }
    }

    private func assertEqualScores(_ actual: Double?, _ expected: Double?, scenarioID: String) {
        switch (actual, expected) {
        case (.none, .none):
            break
        case let (.some(actual), .some(expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "scenario \(scenarioID): selected error")
        default:
            XCTFail("scenario \(scenarioID): expected error \(String(describing: expected)), got \(String(describing: actual))")
        }
    }
}

private struct IndexedCandidate {
    let index: Int
    let color: PaletteColor
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let missingPolicy: String
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [CandidateFixture]
    let target: [String: Double]
    let weights: [String: Double]
    let expected: ExpectedSelection
}

private struct CandidateFixture: Decodable {
    let index: Int
    let hexColor: String
    let channels: [String: Double]
}

private struct ExpectedSelection: Decodable {
    let selectedIndex: Int?
    let error: Double?
    let tiedIndices: [Int]
}
