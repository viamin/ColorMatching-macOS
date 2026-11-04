import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testSelectionsMatchCommittedParityCorpus() throws {
        let corpus = try loadCorpus()

        for testCase in corpus.cases {
            let result = try CompositionSolver(scorer: WeightedSquaredErrorScorer()).solve(
                palette: testCase.palette.map(makeColor),
                sourceGrids: try testCase.sourceGrids(),
                weights: testCase.channelWeights
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { testCase.palette[$0].id }
            XCTAssertEqual(selectedID, testCase.expectedColorID, testCase.name)
        }
    }

    private func loadCorpus() throws -> WeightedSquaredErrorParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixtureURL = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(WeightedSquaredErrorParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makeColor(_ fixture: WeightedSquaredErrorParityCorpus.Candidate) -> PaletteColor {
        let responses = fixture.responses.reduce(into: [LightingCondition: IlluminationResponse]()) { result, entry in
            result[LightingCondition(rawValue: entry.key)!] = IlluminationResponse(brightness: entry.value)
        }
        return PaletteColor(id: fixture.id, hex: "#000000", rgb: RGBColor(hex: "#000000")!, responses: responses)
    }
}

private struct WeightedSquaredErrorParityCorpus: Decodable {
    struct Candidate: Decodable {
        let id: Int
        let responses: [String: Double]
    }

    struct Case: Decodable {
        let name: String
        let weights: [String: Double]
        let target: [String: Double]
        let palette: [Candidate]
        let expectedColorID: Int?

        enum CodingKeys: String, CodingKey {
            case name, weights, target, palette
            case expectedColorID = "expected_color_id"
        }

        var channelWeights: ChannelWeights {
            ChannelWeights(
                white: weights["white", default: 0], red: weights["red", default: 0],
                green: weights["green", default: 0], blue: weights["blue", default: 0],
                lps: weights["lps", default: 0]
            )
        }

        func sourceGrids() throws -> [LightingCondition: BrightnessGrid] {
            try target.reduce(into: [:]) { result, entry in
                guard let condition = LightingCondition(rawValue: entry.key) else {
                    throw CorpusError.unknownLightingCondition(entry.key)
                }
                result[condition] = BrightnessGrid(width: 1, height: 1, values: [entry.value])
            }
        }
    }

    enum CorpusError: Error {
        case unknownLightingCondition(String)
    }

    let source: String
    let contract: String
    let cases: [Case]
}
