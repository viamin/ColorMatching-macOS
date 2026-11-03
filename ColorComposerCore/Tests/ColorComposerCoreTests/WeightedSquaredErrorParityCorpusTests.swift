import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testSelectionsMatchTheColorMatchingParityCorpus() throws {
        for parityCase in try loadCorpus().cases {
            let palette = parityCase.candidates.map(makePaletteColor)
            let targetGrids = try makeTargetGrids(from: parityCase.target)
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: targetGrids,
                weights: makeWeights(from: parityCase.weights)
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { palette[$0].id }
            XCTAssertEqual(selectedID, parityCase.expectedCandidateID, parityCase.name)
            XCTAssertEqual(
                result.excludedCandidateCount,
                parityCase.expectedExcludedCandidateCount,
                parityCase.name
            )

            if let expectedError = parityCase.expectedError {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, parityCase.name)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, parityCase.name)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        let data = try Data(contentsOf: fixtureURL)
        return try JSONDecoder().decode(ParityCorpus.self, from: data)
    }

    private func makePaletteColor(_ candidate: ParityCandidate) -> PaletteColor {
        let responses = candidate.responses.reduce(into: [LightingCondition: IlluminationResponse]()) {
            $0[LightingCondition(rawValue: $1.key)!] = IlluminationResponse(brightness: $1.value)
        }
        return PaletteColor(
            id: candidate.id,
            hex: "#000000",
            rgb: RGBColor(hex: "#000000")!,
            responses: responses
        )
    }

    private func makeTargetGrids(from target: [String: Double]) throws -> [LightingCondition: BrightnessGrid] {
        try target.reduce(into: [LightingCondition: BrightnessGrid]()) {
            guard let condition = LightingCondition(rawValue: $1.key) else {
                throw ParityCorpusError.unknownLightingCondition($1.key)
            }
            $0[condition] = BrightnessGrid(width: 1, height: 1, values: [$1.value])
        }
    }

    private func makeWeights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
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
    let expectedCandidateID: Int?
    let expectedError: Double?
    let expectedExcludedCandidateCount: Int
}

private struct ParityCandidate: Decodable {
    let id: Int
    let responses: [String: Double]
}

private enum ParityCorpusError: Error {
    case unknownLightingCondition(String)
}
