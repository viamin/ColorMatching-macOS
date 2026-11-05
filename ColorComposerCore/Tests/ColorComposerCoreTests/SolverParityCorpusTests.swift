import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        for parityCase in try loadCorpus().cases {
            let result = try CompositionSolver().solve(
                palette: parityCase.candidates.map(makePaletteColor),
                sourceGrids: makeSourceGrids(from: parityCase.target),
                weights: makeWeights(from: parityCase.weights)
            )

            let selectedIndex = try XCTUnwrap(result.colorIndex(x: 0, y: 0), parityCase.name)
            XCTAssertEqual(
                result.palette[selectedIndex].id,
                parityCase.expectedCandidateID,
                parityCase.name
            )
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let corpusURL = testDirectory
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: corpusURL))
    }

    private func makePaletteColor(_ candidate: ParityCandidate) -> PaletteColor {
        let responses = candidate.responses.reduce(into: [LightingCondition: IlluminationResponse]()) {
            $0[LightingCondition(rawValue: $1.key)!] = IlluminationResponse(brightness: $1.value)
        }
        return PaletteColor(id: candidate.id, hex: "#000000", rgb: RGBColor(hex: "#000000")!, responses: responses)
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
}

private struct ParityCorpus: Decodable {
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: [String: Double]
    let target: [String: Double]
    let candidates: [ParityCandidate]
    let expectedCandidateID: Int
}

private struct ParityCandidate: Decodable {
    let id: Int
    let responses: [String: Double]
}
