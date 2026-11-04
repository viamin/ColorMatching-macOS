import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testSelectionsMatchCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.formatVersion, 1)
        XCTAssertEqual(corpus.upstream, "viamin/color_matching#111")

        for parityCase in corpus.cases {
            let result = try solve(parityCase)
            let selectedID = result.colorIndex(x: 0, y: 0).map { parityCase.candidates[$0].id }
            XCTAssertEqual(selectedID, parityCase.expectedWinnerID, parityCase.name)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }

    private func solve(_ parityCase: ParityCase) throws -> CompositionResult {
        let target = try responses(from: parityCase.target)
        let palette = try parityCase.candidates.map { candidate in
            PaletteColor(
                id: candidate.id,
                hex: candidate.hex,
                rgb: try XCTUnwrap(RGBColor(hex: candidate.hex)),
                responses: responses(from: candidate.responses)
            )
        }
        let grids = try target.mapValues { BrightnessGrid(width: 1, height: 1, fill: $0.brightness) }

        return try CompositionSolver().solve(
            palette: palette,
            sourceGrids: grids,
            weights: weights(from: parityCase.weights)
        )
    }

    private func responses(from values: [String: Double]) throws -> [LightingCondition: IlluminationResponse] {
        try Dictionary(uniqueKeysWithValues: values.map { key, value in
            let condition = try XCTUnwrap(LightingCondition(rawValue: key), "Unknown lighting condition: \(key)")
            return (condition, IlluminationResponse(brightness: value))
        })
    }

    private func weights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }
}

private struct ParityCorpus: Decodable {
    let formatVersion: Int
    let upstream: String
    let cases: [ParityCase]

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case upstream
        case cases
    }
}

private struct ParityCase: Decodable {
    let name: String
    let target: [String: Double]
    let weights: [String: Double]
    let candidates: [ParityCandidate]
    let expectedWinnerID: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case target
        case weights
        case candidates
        case expectedWinnerID = "expected_winner_id"
    }
}

private struct ParityCandidate: Decodable {
    let id: Int
    let hex: String
    let responses: [String: Double]
}
