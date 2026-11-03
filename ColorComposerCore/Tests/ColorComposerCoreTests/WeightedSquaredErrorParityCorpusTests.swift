import Foundation
import XCTest
@testable import ColorComposerCore

/// Executes every committed `color_matching` weighted-squared-error fixture
/// through the public solver, which is where tie-breaking is defined.
final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testSelectionsMatchParityCorpusExactly() throws {
        for fixture in try loadCorpus().cases {
            let result = try CompositionSolver().solve(
                palette: fixture.candidates.map(\.paletteColor),
                sourceGrids: fixture.target.sourceGrids,
                weights: fixture.weights.channelWeights
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { fixture.candidates[$0].id }
            XCTAssertEqual(selectedID, fixture.expectedCandidateID, fixture.name)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixtureURL = testDirectory
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }
}

private struct ParityCorpus: Decodable {
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let target: ChannelValues
    let weights: ChannelValues
    let candidates: [ParityCandidate]
    let expectedCandidateID: Int?

    enum CodingKeys: String, CodingKey {
        case name, target, weights, candidates
        case expectedCandidateID = "expected_candidate_id"
    }
}

private struct ParityCandidate: Decodable {
    let id: Int
    let hex: String
    let responses: ChannelValues

    var paletteColor: PaletteColor {
        PaletteColor(
            id: id,
            hex: hex,
            rgb: RGBColor(hex: hex)!,
            responses: responses.illuminationResponses
        )
    }
}

private struct ChannelValues: Decodable {
    let white: Double?
    let red: Double?
    let green: Double?
    let blue: Double?
    let lps: Double?

    var values: [LightingCondition: Double] {
        [
            (.white, white), (.red, red), (.green, green), (.blue, blue), (.lps, lps)
        ].reduce(into: [:]) { values, entry in
            if let value = entry.1 { values[entry.0] = value }
        }
    }

    var sourceGrids: [LightingCondition: BrightnessGrid] {
        values.mapValues { BrightnessGrid(width: 1, height: 1, values: [$0]) }
    }

    var illuminationResponses: [LightingCondition: IlluminationResponse] {
        values.mapValues { IlluminationResponse(brightness: $0) }
    }

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
