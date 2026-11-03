import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertEqual(corpus.source, "viamin/color_matching#111")

        for testCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: testCase.paletteColors,
                sourceGrids: testCase.sourceGrids,
                weights: testCase.channelWeights
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { result.palette[$0].id }
            XCTAssertEqual(selectedID, testCase.expectedPaletteID, testCase.name)
            XCTAssertEqual(
                result.excludedCandidateCount,
                testCase.expectedExcludedCandidateCount,
                testCase.name
            )
            assertError(result.error(x: 0, y: 0), expected: testCase.expectedError, named: testCase.name)
        }
    }

    private func assertError(_ actual: Double, expected: Double?, named testCase: String) {
        guard let expected else {
            return XCTAssertTrue(actual.isInfinite, testCase)
        }
        XCTAssertEqual(actual, expected, accuracy: 1e-12, testCase)
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixtureURL = testFile
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }
}

private struct ParityCorpus: Decodable {
    let schemaVersion: Int
    let source: String
    let cases: [ParityCase]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case source
        case cases
    }
}

private struct ParityCase: Decodable {
    let name: String
    let weights: [String: Double]
    let target: [String: Double]
    let palette: [ParityPaletteColor]
    let expectedPaletteID: Int?
    let expectedError: Double?
    let expectedExcludedCandidateCount: Int

    enum CodingKeys: String, CodingKey {
        case name
        case weights
        case target
        case palette
        case expectedPaletteID = "expected_palette_id"
        case expectedError = "expected_error"
        case expectedExcludedCandidateCount = "expected_excluded_candidate_count"
    }

    var channelWeights: ChannelWeights {
        ChannelWeights(
            white: weights["white", default: 0],
            red: weights["red", default: 0],
            green: weights["green", default: 0],
            blue: weights["blue", default: 0],
            lps: weights["lps", default: 0]
        )
    }

    var paletteColors: [PaletteColor] {
        palette.map { entry in
            PaletteColor(
                id: entry.id,
                hex: "#000000",
                rgb: RGBColor(hex: "#000000")!,
                responses: entry.responses.reduce(into: [:]) { result, response in
                    result[lightingCondition(named: response.key)] = IlluminationResponse(brightness: response.value)
                }
            )
        }
    }

    var sourceGrids: [LightingCondition: BrightnessGrid] {
        target.reduce(into: [:]) { result, response in
            result[lightingCondition(named: response.key)] = BrightnessGrid(width: 1, height: 1, values: [response.value])
        }
    }
}

private struct ParityPaletteColor: Decodable {
    let id: Int
    let responses: [String: Double]
}

private func lightingCondition(named name: String) -> LightingCondition {
    switch name {
    case "white": return .white
    case "red": return .red
    case "green": return .green
    case "blue": return .blue
    case "lps": return .lps
    default: preconditionFailure("Unknown parity-corpus lighting condition: \(name)")
    }
}
