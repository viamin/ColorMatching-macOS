import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.schemaVersion, 1)

        for testCase in corpus.cases {
            let palette = testCase.candidates.map(makePaletteColor)
            let grids = Dictionary(uniqueKeysWithValues: testCase.target.map { condition, value in
                (condition, BrightnessGrid(width: 1, height: 1, values: [value]))
            })
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: grids,
                weights: testCase.weights.channelWeights
            )
            let selectedID = result.colorIndex(x: 0, y: 0).map { palette[$0].id }

            XCTAssertEqual(selectedID, testCase.expectedColorID, testCase.name)
            XCTAssertEqual(
                result.excludedCandidateCount,
                testCase.expectedExcludedCandidateCount,
                testCase.name
            )
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }

    private func makePaletteColor(_ candidate: ParityCorpus.Candidate) -> PaletteColor {
        PaletteColor(
            id: candidate.id,
            hex: "#000000",
            rgb: RGBColor(red: 0, green: 0, blue: 0),
            responses: candidate.responses.mapValues(IlluminationResponse.init(brightness:))
        )
    }
}

private struct ParityCorpus: Decodable {
    let schemaVersion: Int
    let cases: [TestCase]

    struct TestCase: Decodable {
        let name: String
        let weights: Channels
        let target: [LightingCondition: Double]
        let candidates: [Candidate]
        let expectedColorID: Int?
        let expectedExcludedCandidateCount: Int
    }

    struct Candidate: Decodable {
        let id: Int
        let responses: [LightingCondition: Double]
    }

    struct Channels: Decodable {
        let white: Double?
        let red: Double?
        let green: Double?
        let blue: Double?
        let lps: Double?

        var channelWeights: ChannelWeights {
            ChannelWeights(
                white: white ?? 0,
                red: red ?? 0,
                green: green ?? 0,
                blue: blue ?? 0,
                lps: lps ?? 0
            )
        }
    }
}
