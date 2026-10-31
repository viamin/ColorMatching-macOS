import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testSolverSelectionsMatchCommittedParityCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertFalse(corpus.cases.isEmpty)

        for fixture in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: fixture.candidates.map(makePaletteColor),
                sourceGrids: fixture.target.mapValues { BrightnessGrid(width: 1, height: 1, values: [$0]) },
                weights: makeChannelWeights(fixture.weights)
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { fixture.candidates[$0].id }
            XCTAssertEqual(selectedID, fixture.expectedSelectedID, fixture.name)

            if let expectedError = fixture.expectedError {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, fixture.name)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, fixture.name)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }

    private func makePaletteColor(_ candidate: ParityCandidate) -> PaletteColor {
        PaletteColor(
            id: candidate.id,
            hex: "#000000",
            rgb: RGBColor(hex: "#000000")!,
            responses: candidate.responses.reduce(into: [:]) { responses, entry in
                if let condition = LightingCondition(rawValue: entry.key) {
                    responses[condition] = IlluminationResponse(brightness: entry.value)
                }
            }
        )
    }

    private func makeChannelWeights(_ values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values[LightingCondition.white.rawValue] ?? 0,
            red: values[LightingCondition.red.rawValue] ?? 0,
            green: values[LightingCondition.green.rawValue] ?? 0,
            blue: values[LightingCondition.blue.rawValue] ?? 0,
            lps: values[LightingCondition.lps.rawValue] ?? 0
        )
    }
}

private struct ParityCorpus: Decodable {
    let schemaVersion: Int
    let cases: [ParityCase]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case cases
    }
}

private struct ParityCase: Decodable {
    let name: String
    let weights: [String: Double]
    let target: [String: Double]
    let candidates: [ParityCandidate]
    let expectedSelectedID: Int?
    let expectedError: Double?

    enum CodingKeys: String, CodingKey {
        case name, weights, target, candidates
        case expectedSelectedID = "expected_selected_id"
        case expectedError = "expected_error"
    }
}

private struct ParityCandidate: Decodable {
    let id: Int
    let responses: [String: Double]
}
