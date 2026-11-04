import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testCommittedParityCorpusMatchesSolverSelections() throws {
        let corpus = try loadCorpus()

        for parityCase in corpus.cases {
            let palette = parityCase.candidates.map(makeColor)
            let result = try CompositionSolver(scorer: WeightedSquaredErrorScorer()).solve(
                palette: palette,
                sourceGrids: sourceGrids(for: parityCase),
                weights: parityCase.weights.domain
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { palette[$0].id }
            XCTAssertEqual(selectedID, parityCase.expectedCandidateID, parityCase.name)
        }
    }

    private func loadCorpus() throws -> WeightedSquaredErrorParityCorpus {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = directory.appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(WeightedSquaredErrorParityCorpus.self, from: data)
    }

    private func makeColor(_ candidate: WeightedSquaredErrorParityCandidate) -> PaletteColor {
        let responses = candidate.responses.reduce(into: [LightingCondition: IlluminationResponse]()) {
            $0[LightingCondition(rawValue: $1.key)!] = IlluminationResponse(brightness: $1.value)
        }
        return PaletteColor(id: candidate.id, hex: "#000000", rgb: RGBColor(hex: "#000000")!, responses: responses)
    }

    private func sourceGrids(for parityCase: WeightedSquaredErrorParityCase) -> [LightingCondition: BrightnessGrid] {
        parityCase.weights.domain.activeConditions.reduce(into: [:]) { grids, condition in
            grids[condition] = BrightnessGrid(
                width: 1,
                height: 1,
                values: [parityCase.target[condition.rawValue]!]
            )
        }
    }
}

private struct WeightedSquaredErrorParityCorpus: Decodable {
    let cases: [WeightedSquaredErrorParityCase]
}

private struct WeightedSquaredErrorParityCase: Decodable {
    let name: String
    let weights: WeightedSquaredErrorParityWeights
    let target: [String: Double]
    let candidates: [WeightedSquaredErrorParityCandidate]
    let expectedCandidateID: Int?

    enum CodingKeys: String, CodingKey {
        case name, weights, target, candidates
        case expectedCandidateID = "expected_candidate_id"
    }
}

private struct WeightedSquaredErrorParityCandidate: Decodable {
    let id: Int
    let responses: [String: Double]
}

private struct WeightedSquaredErrorParityWeights: Decodable {
    let white: Double?
    let red: Double?
    let green: Double?
    let blue: Double?
    let lps: Double?

    var domain: ChannelWeights {
        ChannelWeights(
            white: white ?? 0,
            red: red ?? 0,
            green: green ?? 0,
            blue: blue ?? 0,
            lps: lps ?? 0
        )
    }
}
