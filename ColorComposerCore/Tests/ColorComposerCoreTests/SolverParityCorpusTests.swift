import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertFalse(corpus.cases.isEmpty)
        XCTAssertEqual(Set(corpus.cases.map(\.id)).count, corpus.cases.count)

        for parityCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: parityCase.candidates.map(makePaletteColor),
                sourceGrids: makeSourceGrids(for: parityCase),
                weights: makeWeights(from: parityCase.weights)
            )
            let selectedID = result.colorIndex(x: 0, y: 0).map { parityCase.candidates[$0].id }

            XCTAssertEqual(selectedID, parityCase.expectedSelectedCandidateID, parityCase.id)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let resourceURL = testFile
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/weighted_squared_error_parity.json")
        let data = try Data(contentsOf: resourceURL)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: data)
    }

    private func makePaletteColor(_ candidate: ParityCandidate) -> PaletteColor {
        let responses = candidate.responses.reduce(into: [LightingCondition: IlluminationResponse]()) { result, entry in
            result[condition(named: entry.key)] = IlluminationResponse(brightness: entry.value)
        }
        return PaletteColor(
            id: candidate.id,
            hex: "#000000",
            rgb: RGBColor(hex: "#000000")!,
            responses: responses
        )
    }

    private func makeSourceGrids(for parityCase: ParityCase) -> [LightingCondition: BrightnessGrid] {
        parityCase.weights.reduce(into: [:]) { result, entry in
            guard entry.value > 0 else { return }
            let condition = condition(named: entry.key)
            result[condition] = BrightnessGrid(
                width: 1,
                height: 1,
                values: [parityCase.target[entry.key]!]
            )
        }
    }

    private func makeWeights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values[LightingCondition.white.rawValue] ?? 0,
            red: values[LightingCondition.red.rawValue] ?? 0,
            green: values[LightingCondition.green.rawValue] ?? 0,
            blue: values[LightingCondition.blue.rawValue] ?? 0,
            lps: values[LightingCondition.lps.rawValue] ?? 0
        )
    }

    private func condition(named name: String) -> LightingCondition {
        guard let condition = LightingCondition(rawValue: name) else {
            fatalError("Unknown lighting condition in parity corpus: \(name)")
        }
        return condition
    }
}

private struct ParityCorpus: Decodable {
    let schemaVersion: Int
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let id: String
    let weights: [String: Double]
    let target: [String: Double]
    let candidates: [ParityCandidate]
    let expectedSelectedCandidateID: Int?
}

private struct ParityCandidate: Decodable {
    let id: Int
    let responses: [String: Double]
}
