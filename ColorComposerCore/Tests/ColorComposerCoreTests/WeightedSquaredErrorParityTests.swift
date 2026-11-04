import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testMatchesCommittedV1ParityCorpusExactly() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            let weights = ChannelWeights(
                white: scenario.weights["white"] ?? 0,
                red: scenario.weights["red"] ?? 0,
                green: scenario.weights["green"] ?? 0,
                blue: scenario.weights["blue"] ?? 0,
                lps: scenario.weights["lps"] ?? 0
            )
            let target = TargetResponseVector(responses(from: scenario.target.channels))
            let candidates = scenario.palette.enumerated().map { index, entry in
                PaletteColor(
                    id: index,
                    hex: entry.hex,
                    rgb: RGBColor(hex: entry.hex)!,
                    responses: responses(from: entry.channels)
                )
            }
            let results = candidates.map { WeightedSquaredErrorScorer().score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(results.map(ParityScore.init), scenario.expected.scores, scenario.id)
            let selected = results.enumerated().compactMap { index, result -> (Int, Double)? in
                guard case .score(let score) = result else { return nil }
                return (index, score)
            }.min { $0.1 < $1.1 }
            XCTAssertEqual(selected?.0, scenario.expected.selectedIndex, scenario.id)
            if let expectedError = scenario.expected.error {
                XCTAssertEqual(try XCTUnwrap(selected?.1), expectedError, accuracy: 1e-12, scenario.id)
            } else {
                XCTAssertNil(selected, scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        channels.reduce(into: [:]) { responses, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            responses[condition] = IlluminationResponse(brightness: entry.value)
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: ParityVector
    let palette: [ParityCandidate]
    let expected: ParityExpected
}

private struct ParityVector: Decodable { let channels: [String: Double] }
private struct ParityCandidate: Decodable { let hex: String; let channels: [String: Double] }
private struct ParityExpected: Decodable { let selectedIndex: Int?; let error: Double?; let scores: [ParityScore] }

private enum ParityScore: Decodable, Equatable {
    case score(Double)
    case excluded

    init(_ result: ScorerResult) {
        switch result {
        case .score(let value): self = .score(value)
        case .excluded: self = .excluded
        }
    }

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(Double.self) { self = .score(value) }
        else if try decoder.singleValueContainer().decode(String.self) == "excluded" { self = .excluded }
        else { throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Expected score or excluded") }
    }
}
