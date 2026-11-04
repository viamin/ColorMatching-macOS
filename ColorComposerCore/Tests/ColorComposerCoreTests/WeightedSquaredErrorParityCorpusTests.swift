import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testCommittedParityCorpusSelectsExpectedColorExactly() throws {
        let corpus = try loadCorpus()

        XCTAssertTrue(corpus.source.contains("viamin/color_matching#111"))
        XCTAssertEqual(corpus.formatVersion, 1)
        XCTAssertFalse(corpus.cases.isEmpty, "The committed parity corpus must not be empty")

        for testCase in corpus.cases {
            let palette = testCase.candidates.map(makeColor)
            let sourceGrids = Dictionary(uniqueKeysWithValues: testCase.target.map { condition, brightness in
                (condition, BrightnessGrid(width: 1, height: 1, values: [brightness]))
            })

            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: sourceGrids,
                weights: testCase.weights
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { palette[$0].id }
            XCTAssertEqual(selectedID, testCase.expectedSelectedID, testCase.id)

            if let expectedError = testCase.expectedError {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, testCase.id)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, testCase.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makeColor(_ candidate: ParityCorpus.Candidate) -> PaletteColor {
        PaletteColor(
            id: candidate.id,
            hex: "#000000",
            rgb: RGBColor(red: 0, green: 0, blue: 0),
            responses: candidate.responses.mapValues { IlluminationResponse(brightness: $0) }
        )
    }
}

private struct ParityCorpus: Decodable {
    let source: String
    let formatVersion: Int
    let cases: [Case]

    struct Case: Decodable {
        let id: String
        let weights: ChannelWeights
        let target: [LightingCondition: Double]
        let candidates: [Candidate]
        let expectedSelectedID: Int?
        let expectedError: Double?
    }

    struct Candidate: Decodable {
        let id: Int
        let responses: [LightingCondition: Double]
    }
}
