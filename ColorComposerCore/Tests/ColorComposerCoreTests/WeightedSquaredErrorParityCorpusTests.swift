import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testSolverSelectionsMatchCommittedParityCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertFalse(corpus.cases.isEmpty)

        for testCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: testCase.palette.map(makePaletteColor),
                sourceGrids: sourceGrids(for: testCase.target, weights: testCase.weights),
                weights: makeWeights(testCase.weights)
            )

            let selectedID = result.colorIndices[0].map { result.palette[$0].id }
            XCTAssertEqual(selectedID, testCase.expected.selectedColorID, testCase.name)
            XCTAssertEqual(result.errors[0], testCase.expected.score, accuracy: 1e-12, testCase.name)
            XCTAssertEqual(
                result.excludedCandidateCount,
                testCase.expected.excludedColorIDs.count,
                testCase.name
            )
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let corpusURL = testFile
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity_corpus.json")
        let data = try Data(contentsOf: corpusURL)
        return try JSONDecoder().decode(ParityCorpus.self, from: data)
    }

    private func makePaletteColor(_ fixture: PaletteFixture) -> PaletteColor {
        PaletteColor(
            id: fixture.id,
            hex: "#000000",
            rgb: RGBColor(red: 0, green: 0, blue: 0),
            responses: fixture.responses.reduce(into: [:]) { responses, entry in
                responses[LightingCondition(rawValue: entry.key)!] = IlluminationResponse(brightness: entry.value)
            }
        )
    }

    private func sourceGrids(for target: [String: Double], weights: WeightFixture) -> [LightingCondition: BrightnessGrid] {
        LightingCondition.all.reduce(into: [:]) { grids, condition in
            guard makeWeights(weights).weight(for: condition) > 0 else { return }
            grids[condition] = BrightnessGrid(width: 1, height: 1, values: [target[condition.rawValue]!])
        }
    }

    private func makeWeights(_ fixture: WeightFixture) -> ChannelWeights {
        ChannelWeights(
            white: fixture.white ?? 0,
            red: fixture.red ?? 0,
            green: fixture.green ?? 0,
            blue: fixture.blue ?? 0,
            lps: fixture.lps ?? 0
        )
    }
}

private struct ParityCorpus: Decodable {
    let schemaVersion: Int
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: WeightFixture
    let target: [String: Double]
    let palette: [PaletteFixture]
    let expected: ExpectedFixture
}

private struct WeightFixture: Decodable {
    let white: Double?
    let red: Double?
    let green: Double?
    let blue: Double?
    let lps: Double?
}

private struct PaletteFixture: Decodable {
    let id: Int
    let responses: [String: Double]
}

private struct ExpectedFixture: Decodable {
    let selectedColorID: Int?
    let score: Double
    let excludedColorIDs: [Int]
}
