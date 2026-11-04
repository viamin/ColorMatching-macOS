import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testCorpusSelectionsMatchWeightedSquaredError() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertFalse(corpus.cases.isEmpty)

        for testCase in corpus.cases {
            let palette = try testCase.palette.map(makePaletteColor)
            let result = try CompositionSolver(scorer: WeightedSquaredErrorScorer()).solve(
                palette: palette,
                sourceGrids: try sourceGrids(for: testCase.target),
                weights: try makeWeights(testCase.weights)
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { palette[$0].id }
            XCTAssertEqual(selectedID, testCase.expectedColorID, testCase.name)
            XCTAssertEqual(
                result.excludedCandidateCount,
                testCase.expectedExcludedCandidateCount,
                testCase.name
            )

            if let expectedScore = testCase.expectedScore {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedScore, accuracy: 1e-12, testCase.name)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, testCase.name)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makePaletteColor(_ entry: CorpusPaletteColor) throws -> PaletteColor {
        let responses = try entry.responses.reduce(into: [LightingCondition: IlluminationResponse]()) {
            $0[try condition(named: $1.key)] = IlluminationResponse(brightness: $1.value)
        }
        return PaletteColor(id: entry.id, hex: "#000000", rgb: try XCTUnwrap(RGBColor(hex: "#000000")), responses: responses)
    }

    private func sourceGrids(for target: [String: Double]) throws -> [LightingCondition: BrightnessGrid] {
        try target.reduce(into: [LightingCondition: BrightnessGrid]()) {
            $0[try condition(named: $1.key)] = BrightnessGrid(width: 1, height: 1, values: [$1.value])
        }
    }

    private func makeWeights(_ values: [String: Double]) throws -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0],
            red: values["red", default: 0],
            green: values["green", default: 0],
            blue: values["blue", default: 0],
            lps: values["lps", default: 0]
        )
    }

    private func condition(named value: String) throws -> LightingCondition {
        try XCTUnwrap(LightingCondition(rawValue: value), "Unknown lighting condition: \(value)")
    }
}

private struct ParityCorpus: Decodable {
    let schemaVersion: Int
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: [String: Double]
    let target: [String: Double]
    let palette: [CorpusPaletteColor]
    let expectedColorID: Int?
    let expectedScore: Double?
    let expectedExcludedCandidateCount: Int

    private enum CodingKeys: String, CodingKey {
        case name, weights, target, palette
        case expectedColorID = "expected_color_id"
        case expectedScore = "expected_score"
        case expectedExcludedCandidateCount = "expected_excluded_candidate_count"
    }
}

private struct CorpusPaletteColor: Decodable {
    let id: Int
    let responses: [String: Double]
}
