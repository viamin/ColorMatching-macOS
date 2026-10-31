import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchCommittedParityCorpus() throws {
        for testCase in try loadCorpus().cases {
            let palette = testCase.palette.map(makeColor)
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: grids(for: testCase.target),
                weights: testCase.weights
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { palette[$0].id }
            XCTAssertEqual(selectedID, testCase.expected.selectedPaletteID, testCase.name)
            XCTAssertEqual(result.excludedCandidateCount, testCase.expected.excludedCandidateCount, testCase.name)

            if let expectedError = testCase.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, testCase.name)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, testCase.name)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory.appendingPathComponent("Fixtures/weighted-squared-error-parity.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makeColor(_ entry: ParityCorpus.PaletteEntry) -> PaletteColor {
        let responses = entry.responses.reduce(into: [LightingCondition: IlluminationResponse]()) {
            $0[$1.key] = IlluminationResponse(brightness: $1.value)
        }
        return PaletteColor(id: entry.id, hex: entry.hex, rgb: RGBColor(hex: entry.hex)!, responses: responses)
    }

    private func grids(for target: [LightingCondition: Double]) -> [LightingCondition: BrightnessGrid] {
        target.mapValues { BrightnessGrid(width: 1, height: 1, values: [$0]) }
    }
}

private struct ParityCorpus: Decodable {
    let cases: [Case]

    struct Case: Decodable {
        let name: String
        let weights: ChannelWeights
        let target: [LightingCondition: Double]
        let palette: [PaletteEntry]
        let expected: Expected
    }

    struct PaletteEntry: Decodable {
        let id: Int
        let hex: String
        let responses: [LightingCondition: Double]
    }

    struct Expected: Decodable {
        let selectedPaletteID: Int?
        let error: Double?
        let excludedCandidateCount: Int
    }
}
