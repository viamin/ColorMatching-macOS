import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionMatchesParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertFalse(corpus.cases.isEmpty, "Parity corpus must contain at least one case")

        for testCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: testCase.candidates.map(makePaletteColor),
                sourceGrids: testCase.target.mapValues { BrightnessGrid(width: 1, height: 1, values: [$0]) },
                weights: makeWeights(testCase.weights)
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { testCase.candidates[$0].id }
            XCTAssertEqual(selectedID, testCase.expected.selectedCandidateID, testCase.name)

            let excludedIDs = testCase.candidates.compactMap { candidate in
                let paletteColor = makePaletteColor(candidate)
                if case .excluded = WeightedSquaredErrorScorer().score(
                    candidate: paletteColor,
                    target: TargetResponseVector(testCase.target),
                    weights: makeWeights(testCase.weights)
                ) {
                    return candidate.id
                }
                return nil
            }
            XCTAssertEqual(excludedIDs.sorted(), testCase.expected.excludedCandidateIDs.sorted(), testCase.name)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let corpusURL = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: corpusURL))
    }

    private func makePaletteColor(_ candidate: ParityCandidate) -> PaletteColor {
        PaletteColor(
            id: candidate.id,
            hex: "#000000",
            rgb: RGBColor(hex: "#000000")!,
            responses: candidate.responses.reduce(into: [:]) { responses, entry in
                responses[entry.key] = IlluminationResponse(brightness: entry.value)
            }
        )
    }

    private func makeWeights(_ values: [LightingCondition: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values[.white] ?? 0,
            red: values[.red] ?? 0,
            green: values[.green] ?? 0,
            blue: values[.blue] ?? 0,
            lps: values[.lps] ?? 0
        )
    }
}

private struct ParityCorpus: Decodable {
    let schemaVersion: Int
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: [LightingCondition: Double]
    let target: [LightingCondition: Double]
    let candidates: [ParityCandidate]
    let expected: ParityExpected
}

private struct ParityCandidate: Decodable {
    let id: Int
    let responses: [LightingCondition: Double]
}

private struct ParityExpected: Decodable {
    let selectedCandidateID: Int?
    let excludedCandidateIDs: [Int]
}
