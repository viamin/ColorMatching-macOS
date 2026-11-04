import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()

        for parityCase in corpus.cases {
            let palette = parityCase.candidates.map { makePaletteColor($0) }
            let target = responseValues(from: parityCase.target)
            let grids = target.mapValues { BrightnessGrid(width: 1, height: 1, values: [$0]) }
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: grids,
                weights: makeWeights(parityCase.weights)
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { palette[$0].id }
            XCTAssertEqual(selectedID, parityCase.expected.selectedCandidateID, parityCase.name)
            XCTAssertEqual(result.excludedCandidateCount, parityCase.expected.excludedCandidateCount, parityCase.name)

            if let expectedScore = parityCase.expected.score {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedScore, accuracy: 1e-12, parityCase.name)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, parityCase.name)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixtureURL = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        let data = try Data(contentsOf: fixtureURL)
        return try JSONDecoder().decode(ParityCorpus.self, from: data)
    }

    private func condition(named name: String) -> LightingCondition {
        guard let condition = LightingCondition(rawValue: name) else {
            fatalError("Unknown lighting condition in parity corpus: \(name)")
        }
        return condition
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

    private func makePaletteColor(_ candidate: ParityCandidate) -> PaletteColor {
        let responses = responseValues(from: candidate.responses).mapValues { IlluminationResponse(brightness: $0) }
        return PaletteColor(
            id: candidate.id,
            hex: candidate.hex,
            rgb: RGBColor(hex: candidate.hex)!,
            responses: responses
        )
    }

    private func responseValues(from values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.map { (condition(named: $0.key), $0.value) })
    }
}

private struct ParityCorpus: Decodable {
    let schemaVersion: Int
    let source: String
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: [String: Double]
    let target: [String: Double]
    let candidates: [ParityCandidate]
    let expected: ParityExpectation
}

private struct ParityCandidate: Decodable {
    let id: Int
    let hex: String
    let responses: [String: Double]
}

private struct ParityExpectation: Decodable {
    let selectedCandidateID: Int?
    let score: Double?
    let excludedCandidateCount: Int
}
