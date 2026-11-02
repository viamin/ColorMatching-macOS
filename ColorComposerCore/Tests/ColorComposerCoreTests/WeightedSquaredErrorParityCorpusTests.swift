import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()

        for testCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: testCase.candidates.map { makePaletteColor($0) },
                sourceGrids: testCase.target.mapValues { BrightnessGrid(width: 1, height: 1, values: [$0]) },
                weights: testCase.weights.channelWeights
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { testCase.candidates[$0].id }
            XCTAssertEqual(selectedID, testCase.expectedSelectedColorID, testCase.name)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makePaletteColor(_ candidate: ParityCandidate) -> PaletteColor {
        PaletteColor(
            id: candidate.id,
            hex: candidate.hex,
            rgb: RGBColor(hex: candidate.hex)!,
            responses: candidate.responses.mapValues { IlluminationResponse(brightness: $0) }
        )
    }
}

private struct ParityCorpus: Decodable {
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: ParityWeights
    let target: [LightingCondition: Double]
    let candidates: [ParityCandidate]
    let expectedSelectedColorID: Int?
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
    let responses: [LightingCondition: Double]
}
