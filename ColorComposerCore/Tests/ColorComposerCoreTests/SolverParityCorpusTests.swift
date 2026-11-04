import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()

        for parityCase in corpus.cases {
            let palette = try parityCase.candidates.map(makeColor)
            let grids = Dictionary(
                uniqueKeysWithValues: parityCase.target.map { condition, brightness in
                    (condition, BrightnessGrid(width: 1, height: 1, values: [brightness]))
                }
            )
            let result = try CompositionSolver(scorer: WeightedSquaredErrorScorer()).solve(
                palette: palette,
                sourceGrids: grids,
                weights: makeWeights(parityCase.weights)
            )

            let selectedID = result.colorIndices[0].map { palette[$0].id }
            XCTAssertEqual(selectedID, parityCase.expected.selectedCandidateID, parityCase.name)
            XCTAssertEqual(result.excludedCandidateCount, parityCase.expected.excludedCandidateCount, parityCase.name)

            if let expectedError = parityCase.expected.error {
                XCTAssertEqual(result.errors[0], expectedError, accuracy: 1e-12, parityCase.name)
            } else {
                XCTAssertTrue(result.errors[0].isInfinite, parityCase.name)
            }
        }
    }

    func testParityCorpusCoversContractEdgeCases() throws {
        let corpus = try loadCorpus()
        let tags = Set(corpus.cases.flatMap(\.tags))

        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertEqual(corpus.source.repository, "viamin/color_matching")
        XCTAssertEqual(corpus.source.pullRequest, 111)
        XCTAssertTrue(tags.contains("tie"))
        XCTAssertTrue(tags.contains("exclusion"))
        XCTAssertTrue(tags.contains("zero_weight"))
        XCTAssertTrue(tags.contains("weights"))
    }

    private func loadCorpus() throws -> SolverParityCorpus {
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SolverParityCorpus.self, from: Data(contentsOf: fileURL))
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

    private func makeColor(_ candidate: SolverParityCandidate) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: candidate.hex), "Invalid fixture color: \(candidate.id)")
        let responses = candidate.responses.mapValues { IlluminationResponse(brightness: $0) }
        return PaletteColor(id: candidate.id, hex: candidate.hex, rgb: rgb, responses: responses)
    }
}

private struct SolverParityCorpus: Decodable {
    let schemaVersion: Int
    let source: SolverParitySource
    let cases: [SolverParityCase]
}

private struct SolverParitySource: Decodable {
    let repository: String
    let pullRequest: Int
    let path: String
}

private struct SolverParityCase: Decodable {
    let name: String
    let tags: [String]
    let weights: [LightingCondition: Double]
    let target: [LightingCondition: Double]
    let candidates: [SolverParityCandidate]
    let expected: SolverParityExpected
}

private struct SolverParityCandidate: Decodable {
    let id: Int
    let hex: String
    let responses: [LightingCondition: Double]
}

private struct SolverParityExpected: Decodable {
    let selectedCandidateID: Int?
    let error: Double?
    let excludedCandidateCount: Int
}
