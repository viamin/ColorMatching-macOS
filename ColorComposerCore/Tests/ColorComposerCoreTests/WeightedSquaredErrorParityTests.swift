import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testCommittedCorpusHasExpectedContractStamp() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.scenarios.map(\.id), [
            "distinct-errors", "tie-symmetric-around-target", "tie-duplicate-vectors",
            "tie-three-way-on-lps", "missing-candidate-excluded", "missing-target-excluded",
            "zero-weight-channel-missing", "all-excluded", "single-channel-lps",
            "exact-match-zero-error", "unknown-weight-ignored", "mixed-large-palette"
        ])
    }

    func testWeightedSquaredErrorReplaysCommittedParityCorpus() throws {
        let scorer = WeightedSquaredErrorScorer()

        for scenario in try loadCorpus().scenarios {
            let palette = scenario.palette.map(makePaletteColor)
            let target = TargetResponseVector(responses(from: scenario.target.channels))
            let weights = makeWeights(scenario.weights)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(actualScores, scenario.expected.scores.map(\.scorerResult), scenario.id)

            let selected = selectEarliestMinimum(actualScores)
            XCTAssertEqual(selected?.index, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(selected.map { palette[$0.index].hex }, scenario.expected.selectedHexColor, scenario.id)
            XCTAssertEqual(selected?.score, scenario.expected.error, scenario.id)

            let tiedIndices = actualScores.enumerated().compactMap { index, result -> Int? in
                guard case .score(let score) = result, score == selected?.score else { return nil }
                return index
            }
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
            XCTAssertEqual(tiedIndices.count > 1, scenario.expected.tieBroke ?? false, scenario.id)

            if let selected {
                XCTAssertEqual(selected.index, tiedIndices.first, scenario.id)
            }

            if let grids = sourceGrids(for: scenario.target, weights: weights) {
                let solution = try CompositionSolver().solve(
                    palette: palette,
                    sourceGrids: grids,
                    weights: weights
                )
                XCTAssertEqual(solution.colorIndices, [scenario.expected.selectedIndex], scenario.id)
                XCTAssertEqual(solution.errors, [scenario.expected.error ?? .infinity], scenario.id)
            } else {
                XCTAssertNil(scenario.expected.selectedIndex, scenario.id)
            }
        }
    }

    func testPackageManifestDeclaresGeneratedOpenAPIClientDependencies() throws {
        let manifest = try String(contentsOf: packageManifestURL(), encoding: .utf8)

        XCTAssertTrue(manifest.contains("swift-openapi-runtime"))
        XCTAssertTrue(manifest.contains("swift-openapi-generator"))
        XCTAssertTrue(manifest.contains("OpenAPIRuntime"))
        XCTAssertTrue(manifest.contains("OpenAPIGenerator"))
    }

    private func loadCorpus() throws -> ParityCorpus {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: corpusURL()))
    }

    private func corpusURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
    }

    private func packageManifestURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
    }

    private func makePaletteColor(_ vector: ParityVector) -> PaletteColor {
        PaletteColor(
            id: vector.index ?? 0,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: responses(from: vector.channels)
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, IlluminationResponse(brightness: brightness)) }
        })
    }

    private func makeWeights(_ weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white", default: 0],
            red: weights["red", default: 0],
            green: weights["green", default: 0],
            blue: weights["blue", default: 0],
            lps: weights["lps", default: 0]
        )
    }

    private func sourceGrids(
        for target: ParityVector,
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid]? {
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for (condition, _) in weights.activeEntries {
            guard let brightness = target.channels[condition.rawValue] else { return nil }
            grids[condition] = BrightnessGrid(width: 1, height: 1, values: [brightness])
        }
        return grids
    }

    private func selectEarliestMinimum(_ scores: [ScorerResult]) -> (index: Int, score: Double)? {
        scores.enumerated().reduce(nil) { best, entry in
            guard case .score(let score) = entry.element else { return best }
            guard let best else { return (entry.offset, score) }
            return score < best.score ? (entry.offset, score) : best
        }
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
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ParityScoreValue

    var scorerResult: ScorerResult {
        switch score {
        case .excluded: return .excluded
        case .value(let value): return .score(value)
        }
    }
}

private enum ParityScoreValue: Decodable {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }
}
