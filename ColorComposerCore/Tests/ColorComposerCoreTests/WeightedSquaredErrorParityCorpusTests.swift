import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertFalse(corpus.cases.isEmpty)

        for fixture in corpus.cases {
            let palette = fixture.palette.map(makePaletteColor)
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: sourceGrids(from: fixture.target, weights: fixture.weights),
                weights: makeWeights(fixture.weights)
            )

            let actualID = result.colorIndex(x: 0, y: 0).map { palette[$0].id }
            XCTAssertEqual(actualID, fixture.expectedPaletteID, fixture.name)
            XCTAssertEqual(
                result.excludedCandidateCount,
                fixture.expectedExcludedCandidateCount,
                fixture.name
            )
            if let expectedError = fixture.expectedError {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, fixture.name)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, fixture.name)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makePaletteColor(_ fixture: ParityColor) -> PaletteColor {
        let responses = fixture.responses.reduce(into: [LightingCondition: IlluminationResponse]()) {
            $0[LightingCondition(rawValue: $1.key)!] = IlluminationResponse(brightness: $1.value)
        }
        return PaletteColor(id: fixture.id, hex: fixture.hex, rgb: RGBColor(hex: fixture.hex)!, responses: responses)
    }

    private func makeWeights(_ weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white", default: 0],
            red: weights["red", default: 0],
            green: weights["green", default: 0],
            blue: weights["blue", default: 0],
            lps: weights["lps", default: 0]
        )
    }

    private func sourceGrids(
        from target: [String: Double],
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
}

private struct ParityCorpus: Decodable {
    let schemaVersion: Int
    let cases: [ParityCase]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case cases
    }
}

private struct ParityCase: Decodable {
    let name: String
    let weights: [String: Double]
    let target: [String: Double]
    let palette: [ParityColor]
    let expectedPaletteID: Int?
    let expectedError: Double?
    let expectedExcludedCandidateCount: Int

    private enum CodingKeys: String, CodingKey {
        case name, weights, target, palette
        case expectedPaletteID = "expected_palette_id"
        case expectedError = "expected_error"
        case expectedExcludedCandidateCount = "expected_excluded_candidate_count"
    }
}

private struct ParityColor: Decodable {
    let id: Int
    let hex: String
    let responses: [String: Double]
}
