import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()

        for parityCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: parityCase.palette,
                sourceGrids: parityCase.sourceGrids,
                weights: parityCase.weights
            )
            let selectedID = result.colorIndex(x: 0, y: 0).map { result.palette[$0].id }

            XCTAssertEqual(selectedID, parityCase.expectedColorID, parityCase.name)
        }
    }

    private func loadCorpus() throws -> SolverParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-parity.json")
        return try JSONDecoder().decode(SolverParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }
}

private struct SolverParityCorpus: Decodable {
    let cases: [SolverParityCase]
}

private struct SolverParityCase: Decodable {
    let name: String
    let rawWeights: [LightingCondition: Double]
    let target: [LightingCondition: Double]
    let candidates: [SolverParityCandidate]
    let expectedColorID: Int?

    var palette: [PaletteColor] {
        candidates.map { candidate in
            PaletteColor(
                id: candidate.id,
                hex: "#000000",
                rgb: RGBColor(hex: "#000000")!,
                responses: candidate.responses.mapValues { IlluminationResponse(brightness: $0) }
            )
        }
    }

    var sourceGrids: [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: target.map { condition, brightness in
            (condition, BrightnessGrid(width: 1, height: 1, values: [brightness]))
        })
    }

    var channelWeights: ChannelWeights {
        ChannelWeights(
            white: rawWeights[.white] ?? 0,
            red: rawWeights[.red] ?? 0,
            green: rawWeights[.green] ?? 0,
            blue: rawWeights[.blue] ?? 0,
            lps: rawWeights[.lps] ?? 0
        )
    }

    var weights: ChannelWeights { channelWeights }

    private enum CodingKeys: String, CodingKey {
        case name, target, candidates
        case rawWeights = "weights"
        case expectedColorID = "expected_color_id"
    }
}

private struct SolverParityCandidate: Decodable {
    let id: Int
    let responses: [LightingCondition: Double]
}
