import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()

        for parityCase in corpus.cases {
            let palette = parityCase.candidates.map(makeColor)
            let grids = Dictionary(uniqueKeysWithValues: parityCase.target.map {
                (condition(for: $0.key), BrightnessGrid(width: 1, height: 1, values: [$0.value]))
            })
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: grids,
                weights: makeWeights(parityCase.weights)
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { palette[$0].id }
            XCTAssertEqual(selectedID, parityCase.expectedCandidateID, parityCase.name)

            if let expectedScore = parityCase.expectedScore {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedScore, accuracy: 1e-12, parityCase.name)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, parityCase.name)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makeColor(_ candidate: ParityCandidate) -> PaletteColor {
        let responses = candidate.responses.reduce(into: [LightingCondition: IlluminationResponse]()) {
            $0[condition(for: $1.key)] = IlluminationResponse(brightness: $1.value)
        }
        return PaletteColor(id: candidate.id, hex: "#000000", rgb: RGBColor(hex: "#000000")!, responses: responses)
    }

    private func makeWeights(_ weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white", default: 0],
            red: weights["red", default: 0],
            green: weights["green", default: 0],
            blue: weights["blue", default: 0],
            lps: weights["lps", default: 0]
        )
    }

    private func condition(for name: String) -> LightingCondition {
        guard let condition = LightingCondition(rawValue: name) else {
            fatalError("Unknown parity corpus lighting condition: \(name)")
        }
        return condition
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
    let expectedCandidateID: Int?
    let expectedScore: Double?
}

private struct ParityCandidate: Decodable {
    let id: Int
    let responses: [String: Double]
}
