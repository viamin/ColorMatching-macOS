import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()

        for testCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: testCase.palette.map(makeColor),
                sourceGrids: try makeSourceGrids(for: testCase),
                weights: makeWeights(from: testCase.weights)
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { result.palette[$0].id }
            XCTAssertEqual(selectedID, testCase.expected.selectedID, testCase.name)
            XCTAssertEqual(result.excludedCandidateCount, testCase.expected.excludedIDs.count, testCase.name)
            XCTAssertEqual(result.error(x: 0, y: 0), testCase.expected.score, accuracy: 1e-12, testCase.name)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makeColor(_ candidate: ParityCandidate) -> PaletteColor {
        PaletteColor(
            id: candidate.id,
            hex: "#000000",
            rgb: RGBColor(hex: "#000000")!,
            responses: candidate.responses.reduce(into: [:]) { responses, entry in
                responses[LightingCondition(rawValue: entry.key)!] = IlluminationResponse(brightness: entry.value)
            }
        )
    }

    private func makeSourceGrids(for testCase: ParityCase) throws -> [LightingCondition: BrightnessGrid] {
        try testCase.weights.compactMap { condition, weight in
            guard weight > 0 else { return nil }
            guard let target = testCase.target[condition] else {
                throw ParityCorpusError.missingTarget(testCase.name, condition)
            }
            return (LightingCondition(rawValue: condition)!, BrightnessGrid(width: 1, height: 1, values: [target]))
        }.reduce(into: [:]) { $0[$1.0] = $1.1 }
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
    let source: String
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: [String: Double]
    let target: [String: Double]
    let palette: [ParityCandidate]
    let expected: ParityExpected
}

private struct ParityCandidate: Decodable {
    let id: Int
    let responses: [String: Double]
}

private struct ParityExpected: Decodable {
    let selectedID: Int?
    let score: Double
    let excludedIDs: [Int]

    private enum CodingKeys: String, CodingKey {
        case selectedID = "selected_id"
        case score
        case excludedIDs = "excluded_ids"
    }
}

private enum ParityCorpusError: Error {
    case missingTarget(String, String)
}
