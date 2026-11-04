import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testSelectionsMatchParityCorpusExactly() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.source, "https://github.com/viamin/color_matching/pull/111")

        for parityCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: parityCase.palette.map { makeColor($0) },
                sourceGrids: sourceGrids(for: parityCase),
                weights: parityCase.weights.channelWeights
            )
            let selectedID = result.colorIndex(x: 0, y: 0).map { parityCase.palette[$0].id }

            XCTAssertEqual(selectedID, parityCase.expectedColorID, parityCase.name)
            assertScore(result.error(x: 0, y: 0), equals: parityCase.expectedScore, named: parityCase.name)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makeColor(_ fixture: ParityColor) -> PaletteColor {
        let responses = fixture.responses.reduce(into: [LightingCondition: IlluminationResponse]()) { result, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            result[condition] = IlluminationResponse(brightness: entry.value)
        }
        return PaletteColor(id: fixture.id, hex: "#000000", rgb: RGBColor(hex: "#000000")!, responses: responses)
    }

    private func sourceGrids(for parityCase: ParityCase) -> [LightingCondition: BrightnessGrid] {
        parityCase.weights.channelWeights.activeConditions.reduce(into: [:]) { result, condition in
            result[condition] = BrightnessGrid(
                width: 1,
                height: 1,
                values: [parityCase.target[condition.rawValue] ?? 0]
            )
        }
    }

    private func assertScore(_ actual: Double, equals expected: Double?, named caseName: String) {
        guard let expected else {
            XCTAssertTrue(actual.isInfinite, caseName)
            return
        }
        XCTAssertEqual(actual, expected, accuracy: 1e-12, caseName)
    }
}

private struct ParityCorpus: Decodable {
    let source: String
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: ParityWeights
    let target: [String: Double]
    let palette: [ParityColor]
    let expectedColorID: Int?
    let expectedScore: Double?

    private enum CodingKeys: String, CodingKey {
        case name
        case weights
        case target
        case palette
        case expectedColorID = "expected_color_id"
        case expectedScore = "expected_score"
    }
}

private struct ParityColor: Decodable {
    let id: Int
    let responses: [String: Double]
}

private struct ParityWeights: Decodable {
    let white: Double
    let red: Double
    let green: Double
    let blue: Double
    let lps: Double

    var channelWeights: ChannelWeights {
        ChannelWeights(white: white, red: red, green: green, blue: blue, lps: lps)
    }
}
