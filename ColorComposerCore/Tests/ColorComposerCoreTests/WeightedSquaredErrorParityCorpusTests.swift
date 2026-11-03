import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testSelectionsMatchTheCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.solver, "weighted_squared_error")

        for testCase in corpus.cases {
            let palette = try testCase.palette.map(makePaletteColor)
            let grids = try testCase.target.reduce(into: [LightingCondition: BrightnessGrid]()) { grids, entry in
                grids[try condition(named: entry.key)] = BrightnessGrid(width: 1, height: 1, fill: entry.value)
            }
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: grids,
                weights: makeWeights(testCase.weights)
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { palette[$0].id }
            XCTAssertEqual(selectedID, testCase.expectedColorID, testCase.name)
            XCTAssertEqual(result.excludedCandidateCount, testCase.expectedExcludedCandidateCount, testCase.name)

            if let expectedError = testCase.expectedError {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, testCase.name)
            } else {
                XCTAssertEqual(result.error(x: 0, y: 0), .infinity, testCase.name)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makePaletteColor(_ candidate: ParityCandidate) throws -> PaletteColor {
        let responses = try candidate.responses.reduce(into: [LightingCondition: IlluminationResponse]()) { responses, entry in
            responses[try condition(named: entry.key)] = IlluminationResponse(brightness: entry.value)
        }
        return PaletteColor(id: candidate.id, hex: "#000000", rgb: try XCTUnwrap(RGBColor(hex: "#000000")), responses: responses)
    }

    private func makeWeights(_ weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white", default: 0],
            red: weights["red", default: 0],
            green: weights["green", default: 0],
            blue: weights["blue", default: 0],
            lps: weights["lps", default: 0]
        )
    }

    private func condition(named rawValue: String) throws -> LightingCondition {
        try XCTUnwrap(LightingCondition(rawValue: rawValue), "Unknown lighting condition: \(rawValue)")
    }
}

private struct ParityCorpus: Decodable {
    let solver: String
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: [String: Double]
    let target: [String: Double]
    let palette: [ParityCandidate]
    let expectedColorID: Int?
    let expectedError: Double?
    let expectedExcludedCandidateCount: Int

    enum CodingKeys: String, CodingKey {
        case name, weights, target, palette
        case expectedColorID = "expected_color_id"
        case expectedError = "expected_error"
        case expectedExcludedCandidateCount = "expected_excluded_candidate_count"
    }
}

private struct ParityCandidate: Decodable {
    let id: Int
    let responses: [String: Double]
}
