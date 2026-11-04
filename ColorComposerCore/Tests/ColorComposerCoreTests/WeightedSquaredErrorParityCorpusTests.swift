import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.source.repository, "viamin/color_matching")
        XCTAssertEqual(corpus.source.issue, 111)
        XCTAssertEqual(corpus.source.solver, "WeightedSquaredError")

        for fixture in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: fixture.palette,
                sourceGrids: fixture.sourceGrids,
                weights: fixture.channelWeights
            )
            let selectedID = result.colorIndex(x: 0, y: 0).map { fixture.palette[$0].id }

            XCTAssertEqual(selectedID, fixture.expectedSelectedID, fixture.name)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testDirectory
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("weighted_squared_error_parity_corpus.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }
}

private struct ParityCorpus: Decodable {
    let source: ParityCorpusSource
    let cases: [ParityCase]
}

private struct ParityCorpusSource: Decodable {
    let repository: String
    let issue: Int
    let solver: String
}

private struct ParityCase: Decodable {
    let name: String
    let weights: [String: Double]
    let target: [String: Double]
    let candidates: [ParityCandidate]
    let expectedSelectedID: Int?

    enum CodingKeys: String, CodingKey {
        case name, weights, target, candidates
        case expectedSelectedID = "expected_selected_id"
    }

    var channelWeights: ChannelWeights {
        ChannelWeights(
            white: weights["white"] ?? 0,
            red: weights["red"] ?? 0,
            green: weights["green"] ?? 0,
            blue: weights["blue"] ?? 0,
            lps: weights["lps"] ?? 0
        )
    }

    var sourceGrids: [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: channelWeights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, fill: target[condition.rawValue] ?? 0))
        })
    }

    var palette: [PaletteColor] {
        candidates.map { candidate in
            let responses = candidate.responses.reduce(into: [LightingCondition: IlluminationResponse]()) {
                partialResult, entry in
                guard let condition = LightingCondition(rawValue: entry.key) else { return }
                partialResult[condition] = IlluminationResponse(brightness: entry.value)
            }
            return PaletteColor(
                id: candidate.id,
                hex: "#000000",
                rgb: RGBColor(hex: "#000000")!,
                responses: responses
            )
        }
    }
}

private struct ParityCandidate: Decodable {
    let id: Int
    let responses: [String: Double]
}
