import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpusExactly() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.schemaVersion, 1)

        for testCase in corpus.cases {
            let result = try CompositionSolver(scorer: WeightedSquaredErrorScorer()).solve(
                palette: testCase.palette.map(makeColor),
                sourceGrids: sourceGrids(for: testCase),
                weights: testCase.weights.channelWeights
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { testCase.palette[$0].id }
            XCTAssertEqual(selectedID, testCase.expectedPaletteID, "case: \(testCase.name)")
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func sourceGrids(for testCase: ParityCorpus.Case) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: testCase.target.map { condition, brightness in
            (condition.lightingCondition, BrightnessGrid(width: 1, height: 1, fill: brightness))
        })
    }

    private func makeColor(_ candidate: ParityCorpus.Candidate) -> PaletteColor {
        PaletteColor(
            id: candidate.id,
            hex: "#000000",
            rgb: RGBColor(hex: "#000000")!,
            responses: Dictionary(uniqueKeysWithValues: candidate.responses.map { condition, brightness in
                (condition.lightingCondition, IlluminationResponse(brightness: brightness))
            })
        )
    }
}

private struct ParityCorpus: Decodable {
    struct Case: Decodable {
        let name: String
        let weights: Channels
        let target: Channels
        let palette: [Candidate]
        let expectedPaletteID: Int?

        enum CodingKeys: String, CodingKey {
            case name, weights, target, palette
            case expectedPaletteID = "expected_palette_id"
        }
    }

    struct Candidate: Decodable {
        let id: Int
        let responses: Channels
    }

    struct Channels: Decodable {
        let white: Double?
        let red: Double?
        let green: Double?
        let blue: Double?
        let lps: Double?

        var channelWeights: ChannelWeights {
            ChannelWeights(white: white ?? 0, red: red ?? 0, green: green ?? 0, blue: blue ?? 0, lps: lps ?? 0)
        }

        var values: [(ParityCondition, Double)] {
            [(.white, white), (.red, red), (.green, green), (.blue, blue), (.lps, lps)].compactMap { condition, value in
                value.map { (condition, $0) }
            }
        }
    }

    let schemaVersion: Int
    let cases: [Case]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case cases
    }
}

private enum ParityCondition: String {
    case white, red, green, blue, lps

    var lightingCondition: LightingCondition {
        switch self {
        case .white: .white
        case .red: .red
        case .green: .green
        case .blue: .blue
        case .lps: .lps
        }
    }
}

private extension ParityCorpus.Channels {
    func map<T>(_ transform: (ParityCondition, Double) -> T) -> [T] {
        values.map(transform)
    }
}
