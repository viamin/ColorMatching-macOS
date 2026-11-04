import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchCommittedParityCorpus() throws {
        let corpus = try loadCorpus()

        for testCase in corpus.cases {
            let palette = try testCase.palette.map(makePaletteColor)
            let grids = try Dictionary(uniqueKeysWithValues: testCase.target.map { condition, brightness in
                (try lightingCondition(named: condition), BrightnessGrid(width: 1, height: 1, values: [brightness]))
            })
            let weights = try makeWeights(testCase.weights)

            let result = try CompositionSolver(scorer: WeightedSquaredErrorScorer()).solve(
                palette: palette,
                sourceGrids: grids,
                weights: weights
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { palette[$0].id }
            XCTAssertEqual(selectedID, testCase.expectedColorID, "Corpus case: \(testCase.name)")
        }
    }

    private func loadCorpus(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> WeightedSquaredErrorParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            XCTFail(
                "Missing solver parity corpus from viamin/color_matching#111 at \(fixtureURL.path)",
                file: file,
                line: line
            )
            throw ParityCorpusError.missingFixture
        }
        return try JSONDecoder().decode(WeightedSquaredErrorParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makePaletteColor(_ fixture: WeightedSquaredErrorParityCase.PaletteColor) throws -> PaletteColor {
        let responses = try Dictionary(uniqueKeysWithValues: fixture.responses.map { condition, brightness in
            (try lightingCondition(named: condition), IlluminationResponse(brightness: brightness))
        })
        return PaletteColor(
            id: fixture.id,
            hex: fixture.hex,
            rgb: try XCTUnwrap(RGBColor(hex: fixture.hex)),
            responses: responses
        )
    }

    private func makeWeights(_ values: [String: Double]) throws -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func lightingCondition(named value: String) throws -> LightingCondition {
        guard let condition = LightingCondition(rawValue: value) else {
            throw ParityCorpusError.unknownLightingCondition(value)
        }
        return condition
    }
}

private struct WeightedSquaredErrorParityCorpus: Decodable {
    let cases: [WeightedSquaredErrorParityCase]
}

private struct WeightedSquaredErrorParityCase: Decodable {
    struct PaletteColor: Decodable {
        let id: Int
        let hex: String
        let responses: [String: Double]
    }

    let name: String
    let weights: [String: Double]
    let target: [String: Double]
    let palette: [PaletteColor]
    let expectedColorID: Int?

    private enum CodingKeys: String, CodingKey {
        case name
        case weights
        case target
        case palette
        case expectedColorID = "expected_color_id"
    }
}

private enum ParityCorpusError: Error {
    case missingFixture
    case unknownLightingCondition(String)
}
