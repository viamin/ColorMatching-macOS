import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionMatchesCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)

        for scenario in corpus.scenarios {
            let result = try CompositionSolver().solve(
                palette: scenario.palette.map(paletteColor),
                sourceGrids: sourceGrids(for: scenario.target.channels),
                weights: channelWeights(from: scenario.weights)
            )

            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
            if let expectedError = scenario.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
            }

            if scenario.expected.tieBroke == true {
                XCTAssertEqual(scenario.expected.selectedIndex, scenario.expected.tiedIndices.min(), scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> Corpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory.appendingPathComponent("Fixtures/color_matching_solver_parity_v1.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: fixture))
    }

    private func paletteColor(_ candidate: Candidate) -> PaletteColor {
        let responses = candidate.channels.reduce(into: [LightingCondition: IlluminationResponse]()) { result, entry in
            if let condition = LightingCondition(rawValue: entry.key) {
                result[condition] = IlluminationResponse(brightness: entry.value)
            }
        }
        return PaletteColor(
            id: candidate.index,
            hex: candidate.hexColor,
            rgb: RGBColor(hex: candidate.hexColor)!,
            responses: responses
        )
    }

    private func sourceGrids(for channels: [String: Double]) -> [LightingCondition: BrightnessGrid] {
        channels.reduce(into: [LightingCondition: BrightnessGrid]()) { result, entry in
            if let condition = LightingCondition(rawValue: entry.key) {
                result[condition] = BrightnessGrid(width: 1, height: 1, values: [entry.value])
            }
        }
    }

    private func channelWeights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let palette: [Candidate]
    let target: Target
    let weights: [String: Double]
    let expected: Expected
}

private struct Candidate: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int
}

private struct Target: Decodable {
    let channels: [String: Double]
}

private struct Expected: Decodable {
    let error: Double?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}
