import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.source, "viamin/color_matching#111")

        for parityCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: parityCase.palette.map(makeColor),
                sourceGrids: makeSourceGrids(from: parityCase.target),
                weights: makeWeights(from: parityCase.weights)
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { parityCase.palette[$0].id }
            XCTAssertEqual(selectedID, parityCase.expected.paletteID, parityCase.name)
            XCTAssertEqual(result.excludedCandidateCount, parityCase.expected.excludedCandidateCount, parityCase.name)
            assertError(result.error(x: 0, y: 0), matches: parityCase.expected.error, caseName: parityCase.name)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixture = testFile.deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity_corpus.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makeColor(_ fixture: PaletteFixture) -> PaletteColor {
        let responses = fixture.responses.reduce(into: [LightingCondition: IlluminationResponse]()) { result, entry in
            result[lightingCondition(named: entry.key)] = IlluminationResponse(brightness: entry.value)
        }
        return PaletteColor(id: fixture.id, hex: fixture.hex, rgb: RGBColor(hex: fixture.hex)!, responses: responses)
    }

    private func makeSourceGrids(from target: [String: Double]) -> [LightingCondition: BrightnessGrid] {
        target.reduce(into: [LightingCondition: BrightnessGrid]()) { result, entry in
            result[lightingCondition(named: entry.key)] = BrightnessGrid(width: 1, height: 1, values: [entry.value])
        }
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

    private func lightingCondition(named name: String) -> LightingCondition {
        guard let condition = LightingCondition(rawValue: name) else {
            fatalError("Unknown lighting condition in parity corpus: \(name)")
        }
        return condition
    }

    private func assertError(_ actual: Double, matches expected: ParityError, caseName: String) {
        switch expected {
        case .finite(let value):
            XCTAssertEqual(actual, value, accuracy: 1e-12, caseName)
        case .infinity:
            XCTAssertTrue(actual.isInfinite, caseName)
        }
    }
}

private struct ParityCorpus: Decodable {
    let source: String
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: [String: Double]
    let target: [String: Double]
    let palette: [PaletteFixture]
    let expected: ExpectedSelection
}

private struct PaletteFixture: Decodable {
    let id: Int
    let hex: String
    let responses: [String: Double]
}

private struct ExpectedSelection: Decodable {
    let paletteID: Int?
    let error: ParityError
    let excludedCandidateCount: Int

    private enum CodingKeys: String, CodingKey {
        case paletteID = "palette_id"
        case error
        case excludedCandidateCount = "excluded_candidate_count"
    }
}

private enum ParityError: Decodable {
    case finite(Double)
    case infinity

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .finite(value)
        } else if try container.decode(String.self) == "infinity" {
            self = .infinity
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a number or infinity")
        }
    }
}
