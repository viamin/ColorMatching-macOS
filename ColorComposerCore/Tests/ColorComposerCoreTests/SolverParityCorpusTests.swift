import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        for testCase in try loadCorpus().cases {
            let result = try CompositionSolver().solve(
                palette: testCase.palette.map(makeColor),
                sourceGrids: sourceGrids(for: testCase),
                weights: testCase.weights.channelWeights
            )

            let actualID = result.colorIndices[0].map { result.palette[$0].id }
            XCTAssertEqual(actualID, testCase.expected.selectedColorID, testCase.name)
            XCTAssertEqual(result.excludedCandidateCount, testCase.expected.excludedCandidateCount, testCase.name)

            if let expectedError = testCase.expected.error {
                XCTAssertEqual(result.errors[0], expectedError, accuracy: 1e-12, testCase.name)
            } else {
                XCTAssertTrue(result.errors[0].isInfinite, testCase.name)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixture = testFile
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makeColor(_ candidate: ParityCandidate) -> PaletteColor {
        let responses = candidate.responses.reduce(into: [LightingCondition: IlluminationResponse]()) {
            $0[LightingCondition(rawValue: $1.key)!] = IlluminationResponse(brightness: $1.value)
        }
        return PaletteColor(
            id: candidate.id,
            hex: "#000000",
            rgb: RGBColor(red: 0, green: 0, blue: 0),
            responses: responses
        )
    }

    private func sourceGrids(for testCase: ParityCase) -> [LightingCondition: BrightnessGrid] {
        testCase.target.reduce(into: [LightingCondition: BrightnessGrid]()) {
            $0[LightingCondition(rawValue: $1.key)!] = BrightnessGrid(width: 1, height: 1, fill: $1.value)
        }
    }
}

private struct ParityCorpus: Decodable {
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: ParityWeights
    let target: [String: Double]
    let palette: [ParityCandidate]
    let expected: ParityExpected
}

private struct ParityWeights: Decodable {
    let white: Double?
    let red: Double?
    let green: Double?
    let blue: Double?
    let lps: Double?

    var channelWeights: ChannelWeights {
        ChannelWeights(
            white: white ?? 0,
            red: red ?? 0,
            green: green ?? 0,
            blue: blue ?? 0,
            lps: lps ?? 0
        )
    }
}

private struct ParityCandidate: Decodable {
    let id: Int
    let responses: [String: Double]
}

private struct ParityExpected: Decodable {
    let selectedColorID: Int?
    let excludedCandidateCount: Int
    let error: Double?
}
