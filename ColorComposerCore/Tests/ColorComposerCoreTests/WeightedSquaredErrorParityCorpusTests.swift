import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.corpus, "issue-39 parity corpus seed")
        XCTAssertEqual(corpus.formatVersion, 1)
        XCTAssertFalse(corpus.cases.isEmpty)

        for parityCase in corpus.cases {
            let palette = try parityCase.candidates.map(makeColor)
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: makeSourceGrids(for: parityCase),
                weights: makeWeights(from: parityCase.weights)
            )

            let selectedIndex = try XCTUnwrap(result.colorIndex(x: 0, y: 0), parityCase.name)
            XCTAssertEqual(
                palette[selectedIndex].id,
                parityCase.expected.selectedID,
                "\(parityCase.name): selected candidate",
                file: #filePath,
                line: #line
            )
            XCTAssertEqual(
                result.error(x: 0, y: 0),
                parityCase.expected.score,
                accuracy: 1e-12,
                "\(parityCase.name): score",
                file: #filePath,
                line: #line
            )
            XCTAssertEqual(
                excludedIDs(in: palette, target: parityCase.target, weights: parityCase.weights),
                parityCase.expected.excludedIDs,
                "\(parityCase.name): excluded candidates",
                file: #filePath,
                line: #line
            )
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let file = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: file))
    }

    private func makeColor(_ candidate: ParityCandidate) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: candidate.hex), "Invalid corpus hex: \(candidate.hex)")
        let responses = conditionValues(candidate.responses).mapValues {
            IlluminationResponse(brightness: $0)
        }
        return PaletteColor(id: candidate.id, hex: candidate.hex, rgb: rgb, responses: responses)
    }

    private func makeSourceGrids(for parityCase: ParityCase) -> [LightingCondition: BrightnessGrid] {
        conditionValues(parityCase.target).mapValues { BrightnessGrid(width: 1, height: 1, values: [$0]) }
    }

    private func makeWeights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0],
            red: values["red", default: 0],
            green: values["green", default: 0],
            blue: values["blue", default: 0],
            lps: values["lps", default: 0]
        )
    }

    private func excludedIDs(
        in palette: [PaletteColor],
        target: [String: Double],
        weights: [String: Double]
    ) -> [Int] {
        let vector = TargetResponseVector(conditionValues(target))
        let channelWeights = makeWeights(from: weights)
        return palette.compactMap {
            WeightedSquaredErrorScorer().score(candidate: $0, target: vector, weights: channelWeights) == .excluded ? $0.id : nil
        }
    }

    private func conditionValues(_ values: [String: Double]) -> [LightingCondition: Double] {
        values.reduce(into: [:]) { result, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else {
                XCTFail("Unknown lighting condition in parity corpus: \(entry.key)")
                return
            }
            result[condition] = entry.value
        }
    }
}

private struct ParityCorpus: Decodable {
    let corpus: String
    let formatVersion: Int
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: [String: Double]
    let target: [String: Double]
    let candidates: [ParityCandidate]
    let expected: ParityExpected
}

private struct ParityCandidate: Decodable {
    let id: Int
    let hex: String
    let responses: [String: Double]
}

private struct ParityExpected: Decodable {
    let selectedID: Int
    let score: Double
    let excludedIDs: [Int]
}
