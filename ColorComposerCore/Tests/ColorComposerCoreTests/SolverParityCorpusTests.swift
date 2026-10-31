import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertEqual(corpus.upstream, "viamin/color_matching#111")

        for testCase in corpus.cases {
            let palette = testCase.candidates.map(makePaletteColor)
            let grids = testCase.target.mapValues { BrightnessGrid(width: 1, height: 1, fill: $0) }
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: grids,
                weights: makeWeights(testCase.weights)
            )

            let actualID = result.colorIndex(x: 0, y: 0).map { palette[$0].id }
            XCTAssertEqual(actualID, testCase.expectedPaletteID, testCase.name)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let url = testFile.deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }

    private func makePaletteColor(_ candidate: ParityCandidate) -> PaletteColor {
        let responses = candidate.responses.mapValues { IlluminationResponse(brightness: $0) }
        return PaletteColor(
            id: candidate.id,
            hex: candidate.hex,
            rgb: RGBColor(hex: candidate.hex)!,
            responses: responses
        )
    }

    private func makeWeights(_ weights: [LightingCondition: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights[.white] ?? 0,
            red: weights[.red] ?? 0,
            green: weights[.green] ?? 0,
            blue: weights[.blue] ?? 0,
            lps: weights[.lps] ?? 0
        )
    }
}

private struct ParityCorpus: Decodable {
    let schemaVersion: Int
    let upstream: String
    let cases: [ParityCase]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case upstream, cases
    }
}

private struct ParityCase: Decodable {
    let name: String
    let weights: [LightingCondition: Double]
    let target: [LightingCondition: Double]
    let candidates: [ParityCandidate]
    let expectedPaletteID: Int?

    private enum CodingKeys: String, CodingKey {
        case name, weights, target, candidates
        case expectedPaletteID = "expected_palette_id"
    }
}

private struct ParityCandidate: Decodable {
    let id: Int
    let hex: String
    let responses: [LightingCondition: Double]
}
