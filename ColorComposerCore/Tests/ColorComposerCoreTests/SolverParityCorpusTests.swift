import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithm, "WeightedSquaredError")
        XCTAssertFalse(corpus.cases.isEmpty)

        for parityCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: palette(from: parityCase.palette),
                sourceGrids: sourceGrids(from: parityCase.target, weights: parityCase.weights),
                weights: weights(from: parityCase.weights)
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { parityCase.palette[$0].id }
            XCTAssertEqual(selectedID, parityCase.expectedColorID, parityCase.name)
            XCTAssertEqual(
                result.excludedCandidateCount,
                parityCase.expectedExcludedCandidateCount,
                parityCase.name
            )

            if let expectedError = parityCase.expectedError {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, parityCase.name)
            } else {
                XCTAssertNil(selectedID, parityCase.name)
                XCTAssertEqual(result.error(x: 0, y: 0), .infinity, parityCase.name)
            }
        }
    }

    private func loadCorpus() throws -> WeightedSquaredErrorParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let corpusURL = testDirectory
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("weighted_squared_error_parity.json")
        return try JSONDecoder().decode(
            WeightedSquaredErrorParityCorpus.self,
            from: Data(contentsOf: corpusURL)
        )
    }

    private func palette(from candidates: [ParityCandidate]) -> [PaletteColor] {
        candidates.map { candidate in
            PaletteColor(
                id: candidate.id,
                hex: "#000000",
                rgb: RGBColor(hex: "#000000")!,
                responses: candidate.responses.reduce(into: [:]) { responses, response in
                    responses[response.key] = IlluminationResponse(brightness: response.value)
                }
            )
        }
    }

    private func sourceGrids(
        from target: [LightingCondition: Double],
        weights: [LightingCondition: Double]
    ) -> [LightingCondition: BrightnessGrid] {
        weights.compactMap { condition, weight in
            guard weight > 0, let brightness = target[condition] else { return nil }
            return (condition, BrightnessGrid(width: 1, height: 1, values: [brightness]))
        }
        .reduce(into: [:]) { grids, entry in
            grids[entry.0] = entry.1
        }
    }

    private func weights(from values: [LightingCondition: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values[.white, default: 0],
            red: values[.red, default: 0],
            green: values[.green, default: 0],
            blue: values[.blue, default: 0],
            lps: values[.lps, default: 0]
        )
    }
}

private struct WeightedSquaredErrorParityCorpus: Decodable {
    let source: URL
    let algorithm: String
    let cases: [WeightedSquaredErrorParityCase]
}

private struct WeightedSquaredErrorParityCase: Decodable {
    let name: String
    let weights: [LightingCondition: Double]
    let target: [LightingCondition: Double]
    let palette: [ParityCandidate]
    let expectedColorID: Int?
    let expectedError: Double?
    let expectedExcludedCandidateCount: Int

    private enum CodingKeys: String, CodingKey {
        case name, weights, target, palette
        case expectedColorID = "expected_color_id"
        case expectedError = "expected_error"
        case expectedExcludedCandidateCount = "expected_excluded_candidate_count"
    }
}

private struct ParityCandidate: Decodable {
    let id: Int
    let responses: [LightingCondition: Double]
}
