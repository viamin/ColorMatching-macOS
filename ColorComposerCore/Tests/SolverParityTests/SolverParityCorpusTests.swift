import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesVersionOneParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = TargetResponseVector(channels: scenario.target.channels)
            let weights = ChannelWeights(channels: scenario.weights)
            let candidates = try scenario.palette.map(PaletteColor.init)

            for expectedScore in scenario.expected.scores {
                let actual = scorer.score(
                    candidate: candidates[expectedScore.index],
                    target: target,
                    weights: weights
                )
                XCTAssertEqual(
                    Score(actual),
                    expectedScore.score,
                    "score mismatch in corpus scenario \(scenario.id), candidate \(expectedScore.index)"
                )
            }

            let selection = selectedIndex(from: candidates, target: target, weights: weights, scorer: scorer)
            XCTAssertEqual(selection.index, scenario.expected.selectedIndex, "selection mismatch in corpus scenario \(scenario.id)")
            if let expectedError = scenario.expected.error {
                XCTAssertEqual(
                    try XCTUnwrap(selection.error),
                    expectedError,
                    accuracy: 1e-12,
                    "error mismatch in corpus scenario \(scenario.id)"
                )
            } else {
                XCTAssertNil(selection.error, "error mismatch in corpus scenario \(scenario.id)")
            }
            XCTAssertEqual(selection.hexColor, scenario.expected.selectedHexColor, "selected color mismatch in corpus scenario \(scenario.id)")
            XCTAssertEqual(selection.tiedIndices, scenario.expected.tiedIndices, "tie mismatch in corpus scenario \(scenario.id)")
            XCTAssertEqual(scenario.expected.tieBroke, scenario.expected.tiedIndices.count > 1, "tie metadata mismatch in corpus scenario \(scenario.id)")
        }
    }

    private func loadCorpus() throws -> Corpus {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "corpus", withExtension: "json", subdirectory: "ParityCorpus/v1"))
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }

    private func selectedIndex(
        from candidates: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights,
        scorer: WeightedSquaredErrorScorer
    ) -> Selection {
        var scored: [(index: Int, error: Double)] = []
        for (index, candidate) in candidates.enumerated() {
            guard case .score(let error) = scorer.score(candidate: candidate, target: target, weights: weights) else { continue }
            scored.append((index, error))
        }

        guard let best = scored.min(by: { $0.error < $1.error }) else {
            return Selection(index: nil, error: nil, hexColor: nil, tiedIndices: [])
        }
        return Selection(
            index: best.index,
            error: best.error,
            hexColor: candidates[best.index].hex,
            tiedIndices: scored.filter { $0.error == best.error }.map(\.index)
        )
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let palette: [CorpusColor]
    let target: CorpusColor
    let weights: [String: Double]
    let expected: Expected
}

private struct CorpusColor: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct Expected: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool
    let tiedIndices: [Int]
}

private struct ExpectedScore: Decodable {
    let index: Int
    let score: Score
}

private enum Score: Decodable, Equatable {
    case value(Double)
    case excluded

    init(_ result: ScorerResult) {
        switch result {
        case .score(let value): self = .value(value)
        case .excluded: self = .excluded
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

private struct Selection {
    let index: Int?
    let error: Double?
    let hexColor: String?
    let tiedIndices: [Int]
}

private extension TargetResponseVector {
    init(channels: [String: Double]) {
        self.init(Dictionary(uniqueKeysWithValues: channels.compactMap { name, value in
            LightingCondition(rawValue: name).map { ($0, value) }
        }))
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

private extension PaletteColor {
    init(_ corpusColor: CorpusColor) throws {
        let responses = Dictionary(uniqueKeysWithValues: corpusColor.channels.compactMap { name, value in
            LightingCondition(rawValue: name).map { ($0, IlluminationResponse(brightness: value)) }
        })
        self.init(
            id: corpusColor.index ?? 0,
            hex: corpusColor.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: corpusColor.hexColor)),
            responses: responses
        )
    }
}
