import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testSelectionsMatchCommittedColorMatchingParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.solver, "weighted_squared_error")

        for testCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: testCase.palette.map(makePaletteColor),
                sourceGrids: sourceGrids(for: testCase.target),
                weights: weights(for: testCase.weights)
            )

            let selectedID = result.colorIndices[0].map { testCase.palette[$0].id }
            XCTAssertEqual(selectedID, testCase.expectedSelectedColorID, testCase.id)
            assertExpectedScore(testCase.expectedScore, actual: result.errors[0], caseID: testCase.id)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixture = testFile.deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makePaletteColor(_ candidate: ParityCandidate) -> PaletteColor {
        PaletteColor(
            id: candidate.id,
            hex: candidate.hex,
            rgb: RGBColor(hex: candidate.hex)!,
            responses: candidate.responses.reduce(into: [:]) { responses, entry in
                responses[condition(named: entry.key)] = IlluminationResponse(brightness: entry.value)
            }
        )
    }

    private func sourceGrids(for target: [String: Double]) -> [LightingCondition: BrightnessGrid] {
        target.reduce(into: [:]) { grids, entry in
            grids[condition(named: entry.key)] = BrightnessGrid(width: 1, height: 1, values: [entry.value])
        }
    }

    private func weights(for values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func condition(named name: String) -> LightingCondition {
        guard let condition = LightingCondition(rawValue: name) else {
            fatalError("Unknown parity corpus lighting condition: \(name)")
        }
        return condition
    }

    private func assertExpectedScore(_ expected: Double?, actual: Double, caseID: String) {
        guard let expected else {
            XCTAssertTrue(actual.isInfinite, caseID)
            return
        }
        XCTAssertEqual(actual, expected, accuracy: 1e-12, caseID)
    }
}

private struct ParityCorpus: Decodable {
    let solver: String
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let id: String
    let weights: [String: Double]
    let target: [String: Double]
    let palette: [ParityCandidate]
    let expectedSelectedColorID: Int?
    let expectedScore: Double?
}

private struct ParityCandidate: Decodable {
    let id: Int
    let hex: String
    let responses: [String: Double]
}
