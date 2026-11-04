import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertFalse(corpus.cases.isEmpty)

        for parityCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: parityCase.candidates.map(makePaletteColor),
                sourceGrids: parityCase.target.mapValues { BrightnessGrid(width: 1, height: 1, values: [$0]) },
                weights: makeWeights(parityCase.weights)
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { parityCase.candidates[$0].id }
            XCTAssertEqual(selectedID, parityCase.expectedCandidateID, parityCase.name)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixture = testFile
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity_corpus.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makePaletteColor(_ candidate: ParityCandidate) -> PaletteColor {
        PaletteColor(
            id: candidate.id,
            hex: "#000000",
            rgb: RGBColor(hex: "#000000")!,
            responses: candidate.responses.mapValues { IlluminationResponse(brightness: $0) }
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
    let upstream: URL
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: [LightingCondition: Double]
    let target: [LightingCondition: Double]
    let candidates: [ParityCandidate]
    let expectedCandidateID: Int
}

private struct ParityCandidate: Decodable {
    let id: Int
    let responses: [LightingCondition: Double]
}
