import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testMatchesColorMatchingParityCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            let target = TargetResponseVector(responses(from: scenario.target.channels))
            let weights = weights(from: scenario.weights)
            let palette = try scenario.palette.map(makePaletteColor)
            XCTAssertEqual(scenario.palette.map(\.index), scenario.expected.scores.map(\.index), scenario.id)
            let actualScores = palette.map {
                WeightedSquaredErrorScorer().score(candidate: $0, target: target, weights: weights)
            }

            XCTAssertEqual(actualScores, scenario.expected.scores.map(\.result), scenario.id)

            let selection = selectEarliest(actualScores)
            XCTAssertEqual(selection.index, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(selection.error, scenario.expected.error, scenario.id)
            XCTAssertEqual(
                selection.index.flatMap { palette[$0].hex },
                scenario.expected.selectedHexColor,
                scenario.id
            )

            let tiedIndices = actualScores.enumerated().compactMap { index, result in
                result == selection.result ? index : nil
            }
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
            XCTAssertEqual(tiedIndices.count > 1, scenario.expected.tieBroke ?? false, scenario.id)

            if let sourceGrids = sourceGrids(from: target, weights: weights) {
                let result = try CompositionSolver().solve(
                    palette: palette,
                    sourceGrids: sourceGrids,
                    weights: weights
                )
                XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
                if let expectedError = scenario.expected.error {
                    XCTAssertEqual(result.error(x: 0, y: 0), expectedError, scenario.id)
                } else {
                    XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
                }
            } else {
                XCTAssertNil(scenario.expected.selectedIndex, scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testDirectory.appendingPathComponent("Fixtures/parity/v1/corpus.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }

    private func makePaletteColor(_ fixture: PaletteFixture) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: fixture.hexColor), "Invalid fixture color \(fixture.hexColor)")
        return PaletteColor(
            id: fixture.index,
            hex: fixture.hexColor,
            rgb: rgb,
            responses: responses(from: fixture.channels)
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, IlluminationResponse(brightness: brightness)) }
        })
    }

    private func weights(from fixture: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: fixture["white"] ?? 0,
            red: fixture["red"] ?? 0,
            green: fixture["green"] ?? 0,
            blue: fixture["blue"] ?? 0,
            lps: fixture["lps"] ?? 0
        )
    }

    private func sourceGrids(
        from target: TargetResponseVector,
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid]? {
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for entry in weights.activeEntries {
            guard let brightness = target.value(for: entry.condition) else { return nil }
            grids[entry.condition] = BrightnessGrid(width: 1, height: 1, values: [brightness])
        }
        return grids
    }

    private func selectEarliest(_ scores: [ScorerResult]) -> (index: Int?, error: Double?, result: ScorerResult?) {
        var bestIndex: Int?
        var bestError: Double?

        for (index, result) in scores.enumerated() {
            guard case let .score(error) = result else { continue }
            if bestError == nil || error < bestError! {
                bestIndex = index
                bestError = error
            }
        }

        return (bestIndex, bestError, bestError.map(ScorerResult.score))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [PaletteFixture]
    let target: PaletteFixture
    let weights: [String: Double]
    let expected: ExpectedSelection
}

private struct PaletteFixture: Decodable {
    let index: Int
    let hexColor: String
    let channels: [String: Double]
}

private struct ExpectedSelection: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ExpectedScore: Decodable {
    let index: Int
    let result: ScorerResult

    private enum CodingKeys: String, CodingKey { case index, score }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        if let score = try? container.decode(Double.self, forKey: .score) {
            result = .score(score)
        } else {
            let marker = try container.decode(String.self, forKey: .score)
            guard marker == "excluded" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .score,
                    in: container,
                    debugDescription: "Expected a number or excluded, found \(marker)"
                )
            }
            result = .excluded
        }
    }
}
