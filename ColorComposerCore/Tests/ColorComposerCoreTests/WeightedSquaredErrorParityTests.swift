import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testMatchesVersionOneParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)

        for scenario in corpus.scenarios {
            let weights = ChannelWeights(channels: scenario.weights)
            let target = TargetResponseVector(channels: scenario.target)
            let palette = scenario.palette.enumerated().map { index, candidate in
                PaletteColor(
                    id: index,
                    hex: candidate.hex,
                    rgb: try! XCTUnwrap(RGBColor(hex: candidate.hex)),
                    responses: candidate.channels.mapValues(IlluminationResponse.init(brightness:))
                )
            }
            let scorer = WeightedSquaredErrorScorer()

            for (index, candidate) in palette.enumerated() {
                let actual = scorer.score(candidate: candidate, target: target, weights: weights)
                if scenario.expected.excluded.contains(index) {
                    XCTAssertEqual(actual, .excluded, scenario.id)
                }
            }

            let grids = Dictionary(uniqueKeysWithValues: target.brightness.map {
                ($0.key, BrightnessGrid(width: 1, height: 1, values: [$0.value]))
            })
            let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)
            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)

            if let expectedError = scenario.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scenarios: [ParityScenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case scenarios
    }
}

private struct ParityScenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: [String: Double]
    let palette: [ParityCandidate]
    let expected: ParityExpected
}

private struct ParityCandidate: Decodable {
    let hex: String
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let selectedIndex: Int?
    let error: Double?
    let excluded: [Int]

    enum CodingKeys: String, CodingKey {
        case selectedIndex = "selected_index"
        case error
        case excluded
    }
}

private extension ChannelWeights {
    init(channels: [String: Double]) {
        self.init(
            white: channels["white"] ?? 0,
            red: channels["red"] ?? 0,
            green: channels["green"] ?? 0,
            blue: channels["blue"] ?? 0,
            lps: channels["lps"] ?? 0
        )
    }
}

private extension TargetResponseVector {
    init(channels: [String: Double]) {
        self.init(Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        }))
    }
}
