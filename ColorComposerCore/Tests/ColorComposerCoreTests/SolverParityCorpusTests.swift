import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertEqual(corpus.algorithm, "WeightedSquaredError")
        XCTAssertFalse(corpus.cases.isEmpty)

        for parityCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: parityCase.candidates.map(makePaletteColor),
                sourceGrids: sourceGrids(for: parityCase.target),
                weights: parityCase.weights.channelWeights
            )

            let selectedIndex = try XCTUnwrap(result.colorIndex(x: 0, y: 0), parityCase.name)
            XCTAssertEqual(
                result.palette[selectedIndex].id,
                parityCase.expectedCandidateID,
                parityCase.name
            )
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixture = testFile.deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makePaletteColor(_ candidate: ParityCandidate) -> PaletteColor {
        let responses = candidate.responses.reduce(into: [LightingCondition: IlluminationResponse]()) {
            $0[LightingCondition(rawValue: $1.key)!] = IlluminationResponse(brightness: $1.value)
        }
        return PaletteColor(
            id: candidate.id,
            hex: "#000000",
            rgb: RGBColor(hex: "#000000")!,
            responses: responses
        )
    }

    private func sourceGrids(for target: [String: Double]) -> [LightingCondition: BrightnessGrid] {
        target.reduce(into: [LightingCondition: BrightnessGrid]()) {
            $0[LightingCondition(rawValue: $1.key)!] = BrightnessGrid(width: 1, height: 1, values: [$1.value])
        }
    }
}

private struct ParityCorpus: Decodable {
    let schemaVersion: Int
    let upstream: String
    let algorithm: String
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: ParityWeights
    let target: [String: Double]
    let candidates: [ParityCandidate]
    let expectedCandidateID: Int
}

private struct ParityCandidate: Decodable {
    let id: Int
    let responses: [String: Double]
}

private struct ParityWeights: Decodable {
    let white: Double?
    let red: Double?
    let green: Double?
    let blue: Double?
    let lps: Double?

    var channelWeights: ChannelWeights {
        ChannelWeights(
            white: white ?? 0,
            red: red ?? 0,
            green: green ?? 0,
            blue: blue ?? 0,
            lps: lps ?? 0
        )
    }
}
