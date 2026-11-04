import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()

        for testCase in corpus.cases {
            let palette = try testCase.palette.map(makeColor)
            let sourceGrids = try Dictionary(uniqueKeysWithValues: testCase.target.map { condition, value in
                (try condition.lightingCondition(), BrightnessGrid(width: 1, height: 1, values: [value]))
            })
            let result = try CompositionSolver(scorer: WeightedSquaredErrorScorer()).solve(
                palette: palette,
                sourceGrids: sourceGrids,
                weights: testCase.weights.channelWeights()
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { palette[$0].id }
            XCTAssertEqual(selectedID, testCase.expected.selectedColorID, testCase.name)
            XCTAssertEqual(result.excludedCandidateCount, testCase.expected.excludedCandidateIDs.count, testCase.name)
            XCTAssertEqual(
                Set(testCase.expected.excludedCandidateIDs),
                excludedIDs(in: palette, target: testCase.target, weights: testCase.weights),
                testCase.name
            )
            if let expectedError = testCase.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, testCase.name)
            }
        }
    }

    private func loadCorpus() throws -> SolverParityCorpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(SolverParityCorpus.self, from: Data(contentsOf: url))
    }

    private func makeColor(_ fixture: SolverParityColor) throws -> PaletteColor {
        let responses = try fixture.responses.reduce(into: [LightingCondition: IlluminationResponse]()) { result, item in
            result[try item.key.lightingCondition()] = IlluminationResponse(brightness: item.value)
        }
        return PaletteColor(
            id: fixture.id,
            hex: fixture.hex,
            rgb: try XCTUnwrap(RGBColor(hex: fixture.hex)),
            responses: responses
        )
    }

    private func excludedIDs(
        in palette: [PaletteColor],
        target: [String: Double],
        weights: SolverParityWeights
    ) -> Set<Int> {
        let vector = TargetResponseVector(
            Dictionary(uniqueKeysWithValues: target.compactMap { condition, value in
                LightingCondition(rawValue: condition).map { ($0, value) }
            })
        )
        let channelWeights = weights.channelWeights()
        let scorer = WeightedSquaredErrorScorer()
        return Set(palette.compactMap {
            scorer.score(candidate: $0, target: vector, weights: channelWeights) == .excluded ? $0.id : nil
        })
    }
}

private struct SolverParityCorpus: Decodable {
    let cases: [SolverParityCase]
}

private struct SolverParityCase: Decodable {
    let name: String
    let weights: SolverParityWeights
    let target: [String: Double]
    let palette: [SolverParityColor]
    let expected: SolverParityExpected
}

private struct SolverParityWeights: Decodable {
    let white: Double?
    let red: Double?
    let green: Double?
    let blue: Double?
    let lps: Double?

    func channelWeights() -> ChannelWeights {
        ChannelWeights(white: white ?? 0, red: red ?? 0, green: green ?? 0, blue: blue ?? 0, lps: lps ?? 0)
    }
}

private struct SolverParityColor: Decodable {
    let id: Int
    let hex: String
    let responses: [String: Double]
}

private struct SolverParityExpected: Decodable {
    let selectedColorID: Int?
    let excludedCandidateIDs: [Int]
    let error: Double?
}

private extension String {
    func lightingCondition() throws -> LightingCondition {
        guard let condition = LightingCondition(rawValue: self) else {
            throw SolverParityCorpusError.unknownLightingCondition(self)
        }
        return condition
    }
}

private enum SolverParityCorpusError: Error {
    case unknownLightingCondition(String)
}
