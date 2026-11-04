import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testSelectionsMatchCommittedParityCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(
            corpus.source,
            "https://github.com/viamin/color_matching/pull/111",
            "Refresh this fixture from the upstream parity corpus, not from local solver behavior."
        )

        for parityCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: parityCase.candidates.map(makePaletteColor),
                sourceGrids: makeSourceGrids(for: parityCase.target),
                weights: makeWeights(from: parityCase.weights)
            )

            let selectedIndex = try XCTUnwrap(
                result.colorIndex(x: 0, y: 0),
                "Expected a selected color for corpus case: \(parityCase.name)"
            )
            XCTAssertEqual(
                result.palette[selectedIndex].id,
                parityCase.expectedColorID,
                "Parity mismatch for corpus case: \(parityCase.name)"
            )
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixtureURL = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makePaletteColor(_ candidate: ParityCandidate) -> PaletteColor {
        PaletteColor(
            id: candidate.id,
            hex: candidate.hex,
            rgb: RGBColor(hex: candidate.hex)!,
            responses: candidate.responses.reduce(into: [:]) { responses, entry in
                responses[LightingCondition(rawValue: entry.key)!] = IlluminationResponse(brightness: entry.value)
            }
        )
    }

    private func makeSourceGrids(for target: [String: Double]) -> [LightingCondition: BrightnessGrid] {
        target.reduce(into: [:]) { grids, entry in
            grids[LightingCondition(rawValue: entry.key)!] = BrightnessGrid(width: 1, height: 1, values: [entry.value])
        }
    }

    private func makeWeights(from weights: [String: Double]) -> ChannelWeights {
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
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: [String: Double]
    let target: [String: Double]
    let candidates: [ParityCandidate]
    let expectedColorID: Int

    enum CodingKeys: String, CodingKey {
        case name, weights, target, candidates
        case expectedColorID = "expected_color_id"
    }
}

private struct ParityCandidate: Decodable {
    let id: Int
    let hex: String
    let responses: [String: Double]
}
