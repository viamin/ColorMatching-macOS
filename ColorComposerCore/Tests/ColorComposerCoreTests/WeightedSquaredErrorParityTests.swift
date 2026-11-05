import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testSelectionsMatchCommittedColorMatchingCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.source, "viamin/color_matching#111")

        for testCase in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: testCase.palette.map(makeColor),
                sourceGrids: makeSourceGrids(for: testCase),
                weights: makeWeights(from: testCase.weights)
            )

            XCTAssertEqual(
                result.colorIndex(x: 0, y: 0).map { result.palette[$0].id },
                testCase.expected.colorID,
                "case: \(testCase.name)"
            )
            XCTAssertEqual(
                result.excludedCandidateCount,
                testCase.expected.excludedCandidateCount,
                "case: \(testCase.name)"
            )
            assertExpectedError(testCase.expected.error, actual: result.error(x: 0, y: 0), name: testCase.name)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixtureURL = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makeColor(_ fixture: ParityPaletteColor) -> PaletteColor {
        let responses = fixture.responses.reduce(into: [LightingCondition: IlluminationResponse]()) { result, entry in
            result[LightingCondition(rawValue: entry.key)!] = IlluminationResponse(brightness: entry.value)
        }
        return PaletteColor(id: fixture.id, hex: "#000000", rgb: RGBColor(hex: "#000000")!, responses: responses)
    }

    private func makeSourceGrids(for testCase: ParityCase) -> [LightingCondition: BrightnessGrid] {
        testCase.target.reduce(into: [:]) { result, entry in
            result[LightingCondition(rawValue: entry.key)!] = BrightnessGrid(width: 1, height: 1, values: [entry.value])
        }
    }

    private func makeWeights(from fixture: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: fixture["white"] ?? 0,
            red: fixture["red"] ?? 0,
            green: fixture["green"] ?? 0,
            blue: fixture["blue"] ?? 0,
            lps: fixture["lps"] ?? 0
        )
    }

    private func assertExpectedError(_ expected: ParityExpectedError, actual: Double, name: String) {
        switch expected {
        case .value(let value):
            XCTAssertEqual(actual, value, accuracy: 1e-12, "case: \(name)")
        case .infinity:
            XCTAssertTrue(actual.isInfinite, "case: \(name)")
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
    let palette: [ParityPaletteColor]
    let expected: ParityExpected
}

private struct ParityPaletteColor: Decodable {
    let id: Int
    let responses: [String: Double]
}

private struct ParityExpected: Decodable {
    let colorID: Int?
    let error: ParityExpectedError
    let excludedCandidateCount: Int

    private enum CodingKeys: String, CodingKey {
        case colorID = "color_id"
        case error
        case excludedCandidateCount = "excluded_candidate_count"
    }
}

private enum ParityExpectedError: Decodable {
    case value(Double)
    case infinity

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else if try container.decode(String.self) == "infinity" {
            self = .infinity
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a number or infinity.")
        }
    }
}
