import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertEqual(corpus.source, "viamin/color_matching#111")
        XCTAssertFalse(corpus.cases.isEmpty)

        for testCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: testCase.palette.map(makePaletteColor),
                sourceGrids: makeSourceGrids(from: testCase.target),
                weights: makeWeights(from: testCase.weights)
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { result.palette[$0].id }
            XCTAssertEqual(selectedID, testCase.expected.selectedColorID, testCase.name)

            if let expectedScore = testCase.expected.score {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedScore, accuracy: 1e-12, testCase.name)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, testCase.name)
            }
        }
    }

    private func loadCorpus() throws -> SolverParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixtureURL = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        let data = try Data(contentsOf: fixtureURL)
        return try JSONDecoder().decode(SolverParityCorpus.self, from: data)
    }

    private func makePaletteColor(_ fixture: SolverParityCase.PaletteEntry) -> PaletteColor {
        PaletteColor(
            id: fixture.id,
            hex: fixture.hex,
            rgb: RGBColor(hex: fixture.hex)!,
            responses: fixture.responses.reduce(into: [:]) { responses, entry in
                responses[LightingCondition(corpusKey: entry.key)] = IlluminationResponse(brightness: entry.value)
            }
        )
    }

    private func makeSourceGrids(from target: [String: Double]) -> [LightingCondition: BrightnessGrid] {
        target.reduce(into: [:]) { grids, entry in
            grids[LightingCondition(corpusKey: entry.key)] = BrightnessGrid(width: 1, height: 1, values: [entry.value])
        }
    }

    private func makeWeights(from weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white", default: 0],
            red: weights["red", default: 0],
            green: weights["green", default: 0],
            blue: weights["blue", default: 0],
            lps: weights["lps", default: 0]
        )
    }
}

private extension LightingCondition {
    init(corpusKey: String) {
        guard let condition = Self(rawValue: corpusKey) else {
            preconditionFailure("Unknown parity corpus lighting condition: \(corpusKey)")
        }
        self = condition
    }
}

private struct SolverParityCorpus: Decodable {
    let schemaVersion: Int
    let source: String
    let cases: [SolverParityCase]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case source, cases
    }
}

private struct SolverParityCase: Decodable {
    struct PaletteEntry: Decodable {
        let id: Int
        let hex: String
        let responses: [String: Double]
    }

    struct Expected: Decodable {
        let selectedColorID: Int?
        let score: Double?

        enum CodingKeys: String, CodingKey {
            case selectedColorID = "selected_color_id"
            case score
        }
    }

    let name: String
    let weights: [String: Double]
    let target: [String: Double]
    let palette: [PaletteEntry]
    let expected: Expected
}
