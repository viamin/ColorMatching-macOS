import Foundation
import XCTest
@testable import ColorComposerCore

/// Executes the committed weighted-squared-error compatibility corpus.  Keep
/// this separate from the scorer unit tests: the corpus is the cross-project
/// contract and includes selection order, not just individual score values.
final class SolverParityTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()

        for testCase in corpus.cases {
            let palette = try testCase.candidates.map(makePaletteColor)
            let grids = try testCase.target.mapValues { value in
                BrightnessGrid(width: 1, height: 1, values: [value])
            }
            let result = try CompositionSolver(scorer: WeightedSquaredErrorScorer()).solve(
                palette: palette,
                sourceGrids: grids,
                weights: testCase.weights.channelWeights
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { palette[$0].id }
            XCTAssertEqual(selectedID, testCase.expected.selectedCandidateID, testCase.name)
            XCTAssertEqual(result.excludedCandidateCount, testCase.expected.excludedCandidateCount, testCase.name)

            if let expectedError = testCase.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, testCase.name)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, testCase.name)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: file))
    }

    private func makePaletteColor(_ candidate: ParityCandidate) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: candidate.hex), "Invalid corpus color \(candidate.id)")
        let responses = try candidate.responses.reduce(into: [LightingCondition: IlluminationResponse]()) {
            $0[try condition(named: $1.key)] = IlluminationResponse(brightness: $1.value)
        }
        return PaletteColor(id: candidate.id, hex: candidate.hex, rgb: rgb, responses: responses)
    }

    private func condition(named name: String) throws -> LightingCondition {
        try XCTUnwrap(LightingCondition(rawValue: name), "Unknown lighting condition \(name)")
    }
}

private struct ParityCorpus: Decodable {
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: ParityWeights
    let target: [String: Double]
    let candidates: [ParityCandidate]
    let expected: ParityExpectation
}

private struct ParityWeights: Decodable {
    let white: Double?
    let red: Double?
    let green: Double?
    let blue: Double?
    let lps: Double?

    var channelWeights: ChannelWeights {
        ChannelWeights(
            white: white ?? 0,
            red: red ?? 0,
            green: green ?? 0,
            blue: blue ?? 0,
            lps: lps ?? 0
        )
    }
}

private struct ParityCandidate: Decodable {
    let id: Int
    let hex: String
    let responses: [String: Double]
}

private struct ParityExpectation: Decodable {
    let selectedCandidateID: Int?
    let excludedCandidateCount: Int
    let error: Double?
}
