import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testSelectionsMatchCommittedParityCorpus() throws {
        let corpus = try loadCorpus()

        for testCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: testCase.candidates.map(paletteColor),
                sourceGrids: sourceGrids(for: testCase.target),
                weights: weights(for: testCase.weights)
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { result.palette[$0].id }
            XCTAssertEqual(selectedID, testCase.expectedCandidateID, testCase.name)

            if let expectedScore = testCase.expectedScore {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedScore, accuracy: 1e-12, testCase.name)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, testCase.name)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let corpusURL = testFile
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity_corpus.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: corpusURL))
    }

    private func paletteColor(_ candidate: ParityCandidate) -> PaletteColor {
        PaletteColor(
            id: candidate.id,
            hex: "#000000",
            rgb: RGBColor(hex: "#000000")!,
            responses: responses(for: candidate.responses)
        )
    }

    private func sourceGrids(for target: [String: Double]) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: target.map { key, value in
            (condition(for: key), BrightnessGrid(width: 1, height: 1, fill: value))
        })
    }

    private func weights(for values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func responses(for values: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        Dictionary(uniqueKeysWithValues: values.map { key, value in
            (condition(for: key), IlluminationResponse(brightness: value))
        })
    }

    private func condition(for value: String) -> LightingCondition {
        guard let condition = LightingCondition(rawValue: value) else {
            fatalError("Unknown parity corpus lighting condition: \(value)")
        }
        return condition
    }
}

private struct ParityCorpus: Decodable {
    let schemaVersion: Int
    let upstreamPullRequest: URL
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: [String: Double]
    let target: [String: Double]
    let candidates: [ParityCandidate]
    let expectedCandidateID: Int?
    let expectedScore: Double?
}

private struct ParityCandidate: Decodable {
    let id: Int
    let responses: [String: Double]
}
