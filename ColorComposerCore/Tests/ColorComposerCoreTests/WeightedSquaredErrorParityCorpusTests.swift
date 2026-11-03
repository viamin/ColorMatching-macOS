import XCTest
@testable import ColorComposerCore

/// Cross-language contract tests for the corpus published by
/// `viamin/color_matching#111`.
///
/// The corpus intentionally records winner IDs rather than palette indexes:
/// solver output is index-based, while backend parity must remain stable when
/// fixture candidates are reordered around a tie.
final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testSelectionsMatchCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.source, "viamin/color_matching#111")
        XCTAssertFalse(corpus.cases.isEmpty, "The parity corpus must contain at least one case.")

        for parityCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: parityCase.candidates.map(makeColor),
                sourceGrids: sourceGrids(for: parityCase),
                weights: channelWeights(for: parityCase.weights)
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { parityCase.candidates[$0].id }
            XCTAssertEqual(selectedID, parityCase.expectedSelectedCandidateID, parityCase.name)
            XCTAssertEqual(result.error(x: 0, y: 0), parityCase.expectedScore, accuracy: 1e-12, parityCase.name)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ParityCorpus.self, from: data)
    }

    private func sourceGrids(for parityCase: ParityCase) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: parityCase.target.map { condition, value in
            (LightingCondition(rawValue: condition)!, BrightnessGrid(width: 1, height: 1, values: [value]))
        })
    }

    private func channelWeights(for values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0],
            red: values["red", default: 0],
            green: values["green", default: 0],
            blue: values["blue", default: 0],
            lps: values["lps", default: 0]
        )
    }

    private func makeColor(_ candidate: ParityCandidate) -> PaletteColor {
        let responses = Dictionary(uniqueKeysWithValues: candidate.responses.map { condition, brightness in
            (LightingCondition(rawValue: condition)!, IlluminationResponse(brightness: brightness))
        })
        return PaletteColor(
            id: candidate.id,
            hex: candidate.hex,
            rgb: RGBColor(hex: candidate.hex)!,
            responses: responses
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
    let candidates: [ParityCandidate]
    let expectedSelectedCandidateID: Int?
    let expectedScore: Double

    private enum CodingKeys: String, CodingKey {
        case name
        case weights
        case target
        case candidates
        case expectedSelectedCandidateID = "expected_selected_candidate_id"
        case expectedScore = "expected_score"
    }
}

private struct ParityCandidate: Decodable {
    let id: Int
    let hex: String
    let responses: [String: Double]
}
