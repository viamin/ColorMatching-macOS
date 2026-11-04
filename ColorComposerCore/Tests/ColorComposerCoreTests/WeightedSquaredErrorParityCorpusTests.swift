import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()

        for testCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: testCase.palette.map(makePaletteColor),
                sourceGrids: makeSourceGrids(from: testCase.target),
                weights: makeWeights(from: testCase.weights)
            )

            XCTAssertEqual(
                result.colorIndex(x: 0, y: 0).map { testCase.palette[$0].id },
                testCase.expected.selectedID,
                "case: \(testCase.id)"
            )
            XCTAssertEqual(
                result.excludedCandidateCount,
                testCase.expected.excludedCandidateCount,
                "case: \(testCase.id)"
            )

            if let expectedScore = testCase.expected.score {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedScore, accuracy: 1e-12, "case: \(testCase.id)")
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, "case: \(testCase.id)")
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity_corpus.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makePaletteColor(_ candidate: ParityCandidate) -> PaletteColor {
        let responses = candidate.responses.reduce(into: [LightingCondition: IlluminationResponse]()) { result, entry in
            result[condition(named: entry.key)] = IlluminationResponse(brightness: entry.value)
        }
        return PaletteColor(id: candidate.id, hex: "#000000", rgb: RGBColor(hex: "#000000")!, responses: responses)
    }

    private func makeSourceGrids(from target: [String: Double]) -> [LightingCondition: BrightnessGrid] {
        target.reduce(into: [LightingCondition: BrightnessGrid]()) { result, entry in
            result[condition(named: entry.key)] = BrightnessGrid(width: 1, height: 1, values: [entry.value])
        }
    }

    private func makeWeights(from weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white", default: 0],
            red: weights["red", default: 0],
            green: weights["green", default: 0],
            blue: weights["blue", default: 0],
            lps: weights["lps", default: 0]
        )
    }

    private func condition(named name: String) -> LightingCondition {
        guard let condition = LightingCondition(rawValue: name) else {
            fatalError("Unknown lighting condition in parity corpus: \(name)")
        }
        return condition
    }
}

private struct ParityCorpus: Decodable {
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let id: String
    let weights: [String: Double]
    let target: [String: Double]
    let palette: [ParityCandidate]
    let expected: ParityExpected
}

private struct ParityCandidate: Decodable {
    let id: Int
    let responses: [String: Double]
}

private struct ParityExpected: Decodable {
    let selectedID: Int?
    let score: Double?
    let excludedCandidateCount: Int
}
