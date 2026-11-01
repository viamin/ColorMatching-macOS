import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        for parityCase in try loadCorpus().cases {
            let result = try CompositionSolver().solve(
                palette: parityCase.palette.map(makePaletteColor),
                sourceGrids: makeSourceGrids(from: parityCase.target),
                weights: makeWeights(from: parityCase.weights)
            )

            let selectedColorID = result.colorIndex(x: 0, y: 0).map { result.palette[$0].id }
            XCTAssertEqual(selectedColorID, parityCase.expectedColorID, parityCase.name)
            XCTAssertEqual(
                result.excludedCandidateCount,
                parityCase.expectedExcludedCandidateCount,
                parityCase.name
            )
            assertError(result.error(x: 0, y: 0), matches: parityCase.expectedError, named: parityCase.name)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let corpusURL = testFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        let data = try Data(contentsOf: corpusURL)
        return try JSONDecoder().decode(ParityCorpus.self, from: data)
    }

    private func makePaletteColor(_ fixture: ParityPaletteColor) -> PaletteColor {
        let responses = fixture.responses.reduce(into: [LightingCondition: IlluminationResponse]()) {
            $0[LightingCondition(rawValue: $1.key)!] = IlluminationResponse(brightness: $1.value)
        }
        return PaletteColor(id: fixture.id, hex: "#000000", rgb: RGBColor(hex: "#000000")!, responses: responses)
    }

    private func makeSourceGrids(from target: [String: Double]) -> [LightingCondition: BrightnessGrid] {
        target.reduce(into: [LightingCondition: BrightnessGrid]()) {
            $0[LightingCondition(rawValue: $1.key)!] = BrightnessGrid(width: 1, height: 1, values: [$1.value])
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

    private func assertError(_ actual: Double, matches expected: Double?, named caseName: String) {
        guard let expected else {
            XCTAssertTrue(actual.isInfinite, caseName)
            return
        }
        XCTAssertEqual(actual, expected, accuracy: 1e-12, caseName)
    }
}

private struct ParityCorpus: Decodable {
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: [String: Double]
    let target: [String: Double]
    let palette: [ParityPaletteColor]
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

private struct ParityPaletteColor: Decodable {
    let id: Int
    let responses: [String: Double]
}
