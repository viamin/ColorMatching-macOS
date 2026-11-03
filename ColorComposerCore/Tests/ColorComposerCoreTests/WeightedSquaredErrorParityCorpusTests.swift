import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testCorpusRecordsImmutableUpstreamRevision() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.source, "viamin/color_matching#111")
        XCTAssertTrue(
            corpus.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
            "Replace the pending fixture with the committed corpus revision from \(corpus.source)."
        )
    }

    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()

        for parityCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: parityCase.candidates.map(makePaletteColor),
                sourceGrids: sourceGrids(for: parityCase.target, weights: parityCase.weights),
                weights: makeWeights(parityCase.weights)
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { result.palette[$0].id }
            XCTAssertEqual(selectedID, parityCase.expectedSelectedColorID, parityCase.name)
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
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: file))
    }

    private func makePaletteColor(_ candidate: ParityCandidate) -> PaletteColor {
        let responses = candidate.responses.reduce(into: [LightingCondition: IlluminationResponse]()) {
            partial, response in
            partial[LightingCondition(rawValue: response.key)!] = IlluminationResponse(brightness: response.value)
        }
        let hex = String(format: "#%06X", candidate.id & 0x00FF_FFFF)
        return PaletteColor(id: candidate.id, hex: hex, rgb: RGBColor(hex: hex)!, responses: responses)
    }

    private func sourceGrids(
        for target: [String: Double],
        weights: [String: Double]
    ) -> [LightingCondition: BrightnessGrid] {
        weights.compactMap { name, weight in
            guard weight > 0, let condition = LightingCondition(rawValue: name), let value = target[name] else {
                return nil
            }
            return (condition, BrightnessGrid(width: 1, height: 1, values: [value]))
        }
        .reduce(into: [:]) { $0[$1.0] = $1.1 }
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
    let source: String
    let revision: String
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: [String: Double]
    let target: [String: Double]
    let candidates: [ParityCandidate]
    let expectedSelectedColorID: Int?
    let expectedError: Double?
    let expectedExcludedCandidateCount: Int

    enum CodingKeys: String, CodingKey {
        case name, weights, target, candidates
        case expectedSelectedColorID = "expected_selected_color_id"
        case expectedError = "expected_error"
        case expectedExcludedCandidateCount = "expected_excluded_candidate_count"
    }
}

private struct ParityCandidate: Decodable {
    let id: Int
    let responses: [String: Double]
}
