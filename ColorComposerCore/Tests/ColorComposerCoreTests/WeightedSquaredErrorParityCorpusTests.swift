import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.formatVersion, 1)

        for testCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: testCase.palette.map(makePaletteColor),
                sourceGrids: makeSourceGrids(target: testCase.target),
                weights: makeWeights(testCase.weights)
            )

            let selectedIndex = try XCTUnwrap(result.colorIndex(x: 0, y: 0), testCase.name)
            XCTAssertEqual(
                result.palette[selectedIndex].id,
                testCase.expected.selectedPaletteID,
                testCase.name
            )
            XCTAssertEqual(result.error(x: 0, y: 0), testCase.expected.error, accuracy: 1e-12, testCase.name)
            XCTAssertEqual(result.excludedCandidateCount, testCase.expected.excludedCandidateCount, testCase.name)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makePaletteColor(_ color: CorpusPaletteColor) -> PaletteColor {
        PaletteColor(
            id: color.id,
            hex: "#000000",
            rgb: RGBColor(hex: "#000000")!,
            responses: color.responses.mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func makeSourceGrids(target: [LightingCondition: Double]) -> [LightingCondition: BrightnessGrid] {
        target.mapValues { BrightnessGrid(width: 1, height: 1, values: [$0]) }
    }

    private func makeWeights(_ weights: CorpusWeights) -> ChannelWeights {
        ChannelWeights(
            white: weights.white ?? 0,
            red: weights.red ?? 0,
            green: weights.green ?? 0,
            blue: weights.blue ?? 0,
            lps: weights.lps ?? 0
        )
    }
}

private struct ParityCorpus: Decodable {
    let formatVersion: Int
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: CorpusWeights
    let target: [LightingCondition: Double]
    let palette: [CorpusPaletteColor]
    let expected: ExpectedSelection
}

private struct CorpusWeights: Decodable {
    let white: Double?
    let red: Double?
    let green: Double?
    let blue: Double?
    let lps: Double?
}

private struct CorpusPaletteColor: Decodable {
    let id: Int
    let responses: [LightingCondition: Double]
}

private struct ExpectedSelection: Decodable {
    let selectedPaletteID: Int
    let error: Double
    let excludedCandidateCount: Int
}
