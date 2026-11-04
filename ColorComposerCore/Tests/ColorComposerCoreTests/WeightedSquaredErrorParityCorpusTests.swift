import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testSelectionsMatchTheCommittedParityCorpusExactly() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertEqual(corpus.source, "viamin/color_matching#111")
        XCTAssertFalse(corpus.cases.isEmpty)

        for parityCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: parityCase.candidates.map(makePaletteColor),
                sourceGrids: sourceGrids(for: parityCase.target),
                weights: makeWeights(from: parityCase.weights)
            )
            let index = try XCTUnwrap(result.colorIndices.first, "\(parityCase.name) did not select a color")

            XCTAssertEqual(
                result.palette[index].id,
                parityCase.expectedColorID,
                "\(parityCase.name)"
            )
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileURL = testDirectory
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("weighted-squared-error-parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fileURL))
    }

    private func makePaletteColor(_ candidate: ParityCandidate) -> PaletteColor {
        let responses = Dictionary(uniqueKeysWithValues: candidate.responses.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, IlluminationResponse(brightness: brightness)) }
        })
        return PaletteColor(id: candidate.id, hex: "#000000", rgb: RGBColor(hex: "#000000")!, responses: responses)
    }

    private func sourceGrids(for target: [String: Double]) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: target.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, BrightnessGrid(width: 1, height: 1, fill: brightness)) }
        })
    }

    private func makeWeights(from weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white"] ?? 0,
            red: weights["red"] ?? 0,
            green: weights["green"] ?? 0,
            blue: weights["blue"] ?? 0,
            lps: weights["lps"] ?? 0
        )
    }
}

private struct ParityCorpus: Decodable {
    let schemaVersion: Int
    let source: String
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: [String: Double]
    let target: [String: Double]
    let candidates: [ParityCandidate]
    let expectedColorID: Int
}

private struct ParityCandidate: Decodable {
    let id: Int
    let responses: [String: Double]
}
