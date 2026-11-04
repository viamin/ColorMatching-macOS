import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testCommittedCorpusMatchesWeightedSquaredErrorSelectionsExactly() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithm, "weighted_squared_error")
        XCTAssertEqual(corpus.source, "viamin/color_matching#111")

        for testCase in corpus.cases {
            let selected = selectCandidate(in: testCase)
            XCTAssertEqual(
                selected?.candidate.id,
                testCase.expectedCandidateID,
                "\(testCase.name): selected candidate"
            )
            assertScore(selected?.score, equals: testCase.expectedScore, for: testCase.name)
        }
    }

    private func loadCorpus() throws -> Corpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }

    private func selectCandidate(in testCase: Corpus.Case) -> (candidate: Corpus.Candidate, score: Double)? {
        let scorer = WeightedSquaredErrorScorer()
        let target = TargetResponseVector(testCase.target.lightingValues)
        let weights = testCase.weights.channelWeights

        return testCase.candidates.reduce(nil as (candidate: Corpus.Candidate, score: Double)?) { best, candidate in
            let paletteColor = PaletteColor(
                id: candidate.id,
                hex: "#000000",
                rgb: RGBColor(red: 0, green: 0, blue: 0),
                responses: candidate.responses.lightingValues.mapValues { IlluminationResponse(brightness: $0) }
            )
            guard case .score(let score) = scorer.score(candidate: paletteColor, target: target, weights: weights) else {
                return best
            }
            guard let best, score >= best.score else { return (candidate, score) }
            return best
        }
    }

    private func assertScore(_ actual: Double?, equals expected: Double?, for name: String) {
        switch (actual, expected) {
        case let (.some(actual), .some(expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "\(name): selected score")
        case (nil, nil):
            break
        default:
            XCTFail("\(name): selected score mismatch")
        }
    }
}

private struct Corpus: Decodable {
    let source: String
    let algorithm: String
    let cases: [Case]

    struct Case: Decodable {
        let name: String
        let weights: Responses
        let target: Responses
        let candidates: [Candidate]
        let expectedCandidateID: Int?
        let expectedScore: Double?
    }

    struct Candidate: Decodable {
        let id: Int
        let responses: Responses
    }

    struct Responses: Decodable {
        let values: [String: Double]

        init(from decoder: Decoder) throws {
            values = try [String: Double](from: decoder)
        }

        var lightingValues: [LightingCondition: Double] {
            Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
                LightingCondition(rawValue: key).map { ($0, value) }
            })
        }

        var channelWeights: ChannelWeights {
            ChannelWeights(
                white: values["white"] ?? 0,
                red: values["red"] ?? 0,
                green: values["green"] ?? 0,
                blue: values["blue"] ?? 0,
                lps: values["lps"] ?? 0
            )
        }
    }
}
