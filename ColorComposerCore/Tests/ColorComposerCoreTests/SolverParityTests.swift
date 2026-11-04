import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()

        for testCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: testCase.palette.map(makeColor),
                sourceGrids: sourceGrids(for: testCase.target),
                weights: makeWeights(testCase.weights)
            )

            let selectedColorID = result.colorIndices[0].map { result.palette[$0].id }
            XCTAssertEqual(
                selectedColorID,
                testCase.expectedSelectedColorID,
                "Parity case \\(testCase.name) selected the wrong color"
            )
        }
    }

    private func loadCorpus() throws -> SolverParityCorpus {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let corpusURL = testFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("ParityCorpus/weighted_squared_error.json")
        return try JSONDecoder().decode(SolverParityCorpus.self, from: Data(contentsOf: corpusURL))
    }

    private func sourceGrids(for target: [String: Double]) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: target.compactMap { condition, brightness in
            LightingCondition(rawValue: condition).map { ($0, BrightnessGrid(width: 1, height: 1, values: [brightness])) }
        })
    }

    private func makeWeights(_ weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights[LightingCondition.white.rawValue] ?? 0,
            red: weights[LightingCondition.red.rawValue] ?? 0,
            green: weights[LightingCondition.green.rawValue] ?? 0,
            blue: weights[LightingCondition.blue.rawValue] ?? 0,
            lps: weights[LightingCondition.lps.rawValue] ?? 0
        )
    }

    private func makeColor(_ fixture: SolverParityCorpus.Color) -> PaletteColor {
        PaletteColor(
            id: fixture.id,
            hex: "#000000",
            rgb: RGBColor(red: 0, green: 0, blue: 0),
            responses: Dictionary(uniqueKeysWithValues: fixture.responses.compactMap { condition, brightness in
                LightingCondition(rawValue: condition).map { ($0, IlluminationResponse(brightness: brightness)) }
            })
        )
    }
}

private struct SolverParityCorpus: Decodable {
    struct Color: Decodable {
        let id: Int
        let responses: [String: Double]
    }

    struct Case: Decodable {
        let name: String
        let target: [String: Double]
        let weights: [String: Double]
        let palette: [Color]
        let expectedSelectedColorID: Int?

        private enum CodingKeys: String, CodingKey {
            case name, target, weights, palette
            case expectedSelectedColorID = "expected_selected_color_id"
        }
    }

    let cases: [Case]
}
