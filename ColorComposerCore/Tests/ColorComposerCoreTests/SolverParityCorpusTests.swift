import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertFalse(corpus.cases.isEmpty, "Parity corpus must contain at least one case")
        for testCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: testCase.palette.map(makePaletteColor),
                sourceGrids: makeSourceGrids(from: testCase.target),
                weights: makeWeights(from: testCase.weights)
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { testCase.palette[$0].id }
            XCTAssertEqual(selectedID, testCase.expected.selectedPaletteID, testCase.name)
        }
    }

    private func loadCorpus() throws -> SolverParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testDirectory
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("weighted_squared_error_parity.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SolverParityCorpus.self, from: Data(contentsOf: url))
    }

    private func makeSourceGrids(from target: [String: Double]) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: target.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, BrightnessGrid(width: 1, height: 1, values: [brightness])) }
        })
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

    private func makePaletteColor(_ entry: SolverParityCorpus.PaletteEntry) -> PaletteColor {
        let responses = Dictionary(uniqueKeysWithValues: entry.responses.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, IlluminationResponse(brightness: brightness)) }
        })
        return PaletteColor(id: entry.id, hex: entry.hex, rgb: RGBColor(hex: entry.hex)!, responses: responses)
    }
}

private struct SolverParityCorpus: Decodable {
    struct TestCase: Decodable {
        struct Expected: Decodable {
            let selectedPaletteID: Int?
        }

        struct PaletteEntry: Decodable {
            let id: Int
            let hex: String
            let responses: [String: Double]
        }

        let name: String
        let weights: [String: Double]
        let target: [String: Double]
        let palette: [PaletteEntry]
        let expected: Expected
    }

    let cases: [TestCase]
}
