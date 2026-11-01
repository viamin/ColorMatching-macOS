import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testSelectionsMatchCommittedParityCorpus() throws {
        for parityCase in try loadCorpus().cases {
            let result = try CompositionSolver().solve(
                palette: parityCase.candidates.map(makeColor),
                sourceGrids: makeSourceGrids(from: parityCase),
                weights: parityCase.weights
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { parityCase.candidates[$0].id }
            XCTAssertEqual(selectedID, parityCase.expectedWinnerID, parityCase.name)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makeSourceGrids(from parityCase: ParityCase) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: parityCase.weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [parityCase.target[condition]!]))
        })
    }

    private func makeColor(_ candidate: ParityCandidate) -> PaletteColor {
        PaletteColor(
            id: candidate.id,
            hex: "#000000",
            rgb: RGBColor(hex: "#000000")!,
            responses: candidate.responses.mapValues(IlluminationResponse.init(brightness:))
        )
    }
}

private struct ParityCorpus: Decodable {
    let source: URL
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: ChannelWeights
    let target: [LightingCondition: Double]
    let candidates: [ParityCandidate]
    let expectedWinnerID: Int?

    private enum CodingKeys: String, CodingKey {
        case name, weights, target, candidates
        case expectedWinnerID = "expected_winner_id"
    }
}

private struct ParityCandidate: Decodable {
    let id: Int
    let responses: [LightingCondition: Double]
}
