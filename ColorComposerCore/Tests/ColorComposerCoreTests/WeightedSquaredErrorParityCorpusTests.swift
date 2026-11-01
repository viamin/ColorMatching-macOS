import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testSelectionsMatchParityCorpusExactly() throws {
        let corpus = try loadCorpus()

        for testCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: testCase.palette,
                sourceGrids: testCase.sourceGrids,
                weights: testCase.weights
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { testCase.candidates[$0].id }
            XCTAssertEqual(selectedID, testCase.selectedColorID, testCase.name)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testDirectory
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }
}

private struct ParityCorpus: Decodable {
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let rawWeights: [String: Double]
    let target: [String: Double]
    let candidates: [ParityCandidate]
    let selectedColorID: Int?

    enum CodingKeys: String, CodingKey {
        case name, target, candidates
        case rawWeights = "weights"
        case selectedColorID = "selected_color_id"
    }

    var palette: [PaletteColor] {
        candidates.map { candidate in
            PaletteColor(
                id: candidate.id,
                hex: "#000000",
                rgb: RGBColor(hex: "#000000")!,
                responses: candidate.responses.reduce(into: [:]) { responses, item in
                    responses[LightingCondition(rawValue: item.key)!] = IlluminationResponse(brightness: item.value)
                }
            )
        }
    }

    var sourceGrids: [LightingCondition: BrightnessGrid] {
        target.reduce(into: [:]) { grids, item in
            grids[LightingCondition(rawValue: item.key)!] = BrightnessGrid(width: 1, height: 1, values: [item.value])
        }
    }

    var channelWeights: [LightingCondition: Double] {
        rawWeights.reduce(into: [:]) { mappedWeights, item in
            mappedWeights[LightingCondition(rawValue: item.key)!] = item.value
        }
    }

    var weights: ChannelWeights {
        let mappedWeights = channelWeights
        return ChannelWeights(
            white: mappedWeights[.white] ?? 0,
            red: mappedWeights[.red] ?? 0,
            green: mappedWeights[.green] ?? 0,
            blue: mappedWeights[.blue] ?? 0,
            lps: mappedWeights[.lps] ?? 0
        )
    }
}

private struct ParityCandidate: Decodable {
    let id: Int
    let responses: [String: Double]
}
