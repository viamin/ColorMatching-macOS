import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testCorpusSelectionsMatchExpectedOutputsExactly() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertFalse(corpus.cases.isEmpty)

        for parityCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: parityCase.palette,
                sourceGrids: parityCase.sourceGrids,
                weights: parityCase.channelWeights
            )

            let winnerID = result.colorIndex(x: 0, y: 0).map { parityCase.candidates[$0].id }
            XCTAssertEqual(winnerID, parityCase.expected.winnerID, parityCase.name)
            XCTAssertEqual(
                result.excludedCandidateCount,
                parityCase.expected.excludedCandidateCount,
                parityCase.name
            )
        }
    }

    private func loadCorpus() throws -> SolverParityCorpus {
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/weighted_squared_error_parity_corpus.json")
        return try JSONDecoder().decode(SolverParityCorpus.self, from: Data(contentsOf: fileURL))
    }
}

private struct SolverParityCorpus: Decodable {
    let schemaVersion: Int
    let cases: [SolverParityCase]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case cases
    }
}

private struct SolverParityCase: Decodable {
    let name: String
    let weights: [LightingCondition: Double]
    let target: [LightingCondition: Double]
    let candidates: [SolverParityCandidate]
    let expected: SolverParityExpected

    var channelWeights: ChannelWeights {
        ChannelWeights(
            white: weights[.white] ?? 0,
            red: weights[.red] ?? 0,
            green: weights[.green] ?? 0,
            blue: weights[.blue] ?? 0,
            lps: weights[.lps] ?? 0
        )
    }

    var palette: [PaletteColor] {
        candidates.map(\.paletteColor)
    }

    var sourceGrids: [LightingCondition: BrightnessGrid] {
        target.mapValues { BrightnessGrid(width: 1, height: 1, values: [$0]) }
    }
}

private struct SolverParityCandidate: Decodable {
    let id: Int
    let hex: String
    let responses: [LightingCondition: Double]

    var paletteColor: PaletteColor {
        PaletteColor(
            id: id,
            hex: hex,
            rgb: RGBColor(hex: hex)!,
            responses: responses.mapValues { IlluminationResponse(brightness: $0) }
        )
    }
}

private struct SolverParityExpected: Decodable {
    let winnerID: Int?
    let excludedCandidateCount: Int

    enum CodingKeys: String, CodingKey {
        case winnerID = "winner_id"
        case excludedCandidateCount = "excluded_candidate_count"
    }
}
