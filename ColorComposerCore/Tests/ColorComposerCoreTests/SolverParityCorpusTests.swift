import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.formatVersion, 1)
        XCTAssertEqual(corpus.solver, "weighted_squared_error")

        for testCase in corpus.cases {
            let palette = testCase.candidates.map(makePaletteColor)
            let weights = makeWeights(testCase.weights)
            let target = TargetResponseVector(makeResponses(testCase.target))
            let grids = target.brightness.mapValues { BrightnessGrid(width: 1, height: 1, values: [$0]) }

            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: grids,
                weights: weights
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { palette[$0].id }
            XCTAssertEqual(selectedID, testCase.expected.selectedColorID, testCase.name)
            XCTAssertEqual(
                result.excludedCandidateCount,
                testCase.expected.excludedColorIDs.count,
                testCase.name
            )
            let excludedIDs = palette.compactMap { candidate -> Int? in
                WeightedSquaredErrorScorer().score(candidate: candidate, target: target, weights: weights) == .excluded
                    ? candidate.id
                    : nil
            }
            XCTAssertEqual(
                excludedIDs,
                testCase.expected.excludedColorIDs,
                testCase.name
            )

            if let expectedScore = testCase.expected.score {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedScore, accuracy: 1e-12, testCase.name)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, testCase.name)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makePaletteColor(_ candidate: ParityCandidate) -> PaletteColor {
        let responses = makeResponses(candidate.responses).mapValues(IlluminationResponse.init(brightness:))
        return PaletteColor(id: candidate.id, hex: "#000000", rgb: RGBColor(hex: "#000000")!, responses: responses)
    }

    private func makeResponses(_ values: [String: Double]) -> [LightingCondition: Double] {
        values.reduce(into: [LightingCondition: Double]()) {
            $0[LightingCondition(rawValue: $1.key)!] = $1.value
        }
    }

    private func makeWeights(_ weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white"] ?? 0,
            red: weights["red"] ?? 0,
            green: weights["green"] ?? 0,
            blue: weights["blue"] ?? 0,
            lps: weights["lps"] ?? 0
        )
    }
}

private struct ParityCorpus: Decodable {
    let formatVersion: Int
    let solver: String
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
    let responses: [String: Double]
}

private struct ParityExpectation: Decodable {
    let selectedColorID: Int?
    let score: Double?
    let excludedColorIDs: [Int]
}
