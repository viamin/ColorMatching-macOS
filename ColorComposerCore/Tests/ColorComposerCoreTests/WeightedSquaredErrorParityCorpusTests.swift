import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertEqual(corpus.upstream, "viamin/color_matching#111")
        XCTAssertTrue(corpus.cases.contains { $0.name.contains("ties") })
        XCTAssertTrue(corpus.cases.contains { $0.name.contains("exclude") })
        XCTAssertTrue(corpus.cases.contains { $0.name.contains("zero-weight") })

        for parityCase in corpus.cases {
            let result = try solve(parityCase)
            let selectedID = result.colorIndices.first.flatMap { result.palette[$0].id }
            let error = try XCTUnwrap(result.errors.first, "\(parityCase.name): expected one result cell")

            XCTAssertEqual(selectedID, parityCase.expectedColorID, parityCase.name)
            XCTAssertEqual(error, parityCase.expectedError, accuracy: 1e-12, parityCase.name)
            XCTAssertEqual(
                result.excludedCandidateCount,
                parityCase.expectedExcludedCandidateCount,
                parityCase.name
            )
        }
    }

    private func solve(_ parityCase: ParityCase) throws -> CompositionResult {
        let weights = ChannelWeights(
            white: parityCase.weights["white"] ?? 0,
            red: parityCase.weights["red"] ?? 0,
            green: parityCase.weights["green"] ?? 0,
            blue: parityCase.weights["blue"] ?? 0,
            lps: parityCase.weights["lps"] ?? 0
        )
        let sourceGrids = try Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            let value = try XCTUnwrap(parityCase.target[condition.rawValue], "\(parityCase.name): missing target")
            return (condition, BrightnessGrid(width: 1, height: 1, values: [value]))
        })

        return try CompositionSolver().solve(
            palette: try parityCase.palette.map(makePaletteColor),
            sourceGrids: sourceGrids,
            weights: weights
        )
    }

    private func makePaletteColor(_ candidate: ParityCandidate) throws -> PaletteColor {
        let responses = try Dictionary(uniqueKeysWithValues: candidate.responses.map { condition, brightness in
            let lightingCondition = try XCTUnwrap(LightingCondition(rawValue: condition), "Unknown condition \(condition)")
            return (lightingCondition, IlluminationResponse(brightness: brightness))
        })
        return PaletteColor(id: candidate.id, hex: "#000000", rgb: RGBColor(hex: "#000000")!, responses: responses)
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }
}

private struct ParityCorpus: Decodable {
    let schemaVersion: Int
    let upstream: String
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: [String: Double]
    let target: [String: Double]
    let palette: [ParityCandidate]
    let expectedColorID: Int?
    let expectedError: Double
    let expectedExcludedCandidateCount: Int
}

private struct ParityCandidate: Decodable {
    let id: Int
    let responses: [String: Double]
}
