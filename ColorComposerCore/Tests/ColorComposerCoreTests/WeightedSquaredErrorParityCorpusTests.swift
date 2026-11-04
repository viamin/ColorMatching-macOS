import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testCorpusHasExpectedFormatAndUpstreamSource() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.format, "color_matching.weighted_squared_error.parity.v1")
        XCTAssertEqual(corpus.source, "https://github.com/viamin/color_matching/pull/111")
        XCTAssertFalse(corpus.cases.isEmpty)
    }

    func testWeightedSquaredErrorSelectionsMatchCorpusExactly() throws {
        let scorer = WeightedSquaredErrorScorer()

        for parityCase in try loadCorpus().cases {
            let palette = parityCase.candidates.map(makeColor)
            let target = TargetResponseVector(responses(from: parityCase.target))
            let weights = makeWeights(parityCase.weights)
            let eligibleIDs = palette.compactMap { color -> Int? in
                guard case .score = scorer.score(candidate: color, target: target, weights: weights) else {
                    return nil
                }
                return color.id
            }

            XCTAssertEqual(
                parityCase.candidates.map(\.id).filter { !eligibleIDs.contains($0) },
                parityCase.expected.excludedCandidateIDs,
                "\(parityCase.name): excluded candidates"
            )

            let result = try CompositionSolver(scorer: scorer).solve(
                palette: palette,
                sourceGrids: sourceGrids(from: parityCase.target),
                weights: weights
            )
            let selectedID = result.colorIndex(x: 0, y: 0).map { palette[$0].id }

            XCTAssertEqual(selectedID, parityCase.expected.selectedID, "\(parityCase.name): selection")
            assertScore(result.error(x: 0, y: 0), equals: parityCase.expected.score, name: parityCase.name)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("weighted_squared_error_parity.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makeColor(_ candidate: ParityCandidate) -> PaletteColor {
        PaletteColor(
            id: candidate.id,
            hex: "#000000",
            rgb: RGBColor(hex: "#000000")!,
            responses: responses(from: candidate.responses).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func responses(from values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { name, value in
            LightingCondition(rawValue: name).map { ($0, value) }
        })
    }

    private func sourceGrids(from target: [String: Double]) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: responses(from: target).map { condition, value in
            (condition, BrightnessGrid(width: 1, height: 1, values: [value]))
        })
    }

    private func makeWeights(_ values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func assertScore(_ actual: Double, equals expected: Double?, name: String) {
        guard let expected else {
            XCTAssertTrue(actual.isInfinite, "\(name): unmatched score")
            return
        }
        XCTAssertEqual(actual, expected, accuracy: 1e-12, "\(name): score")
    }
}

private struct ParityCorpus: Decodable {
    let format: String
    let source: String
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: [String: Double]
    let target: [String: Double]
    let candidates: [ParityCandidate]
    let expected: ParityExpectation
}

private struct ParityCandidate: Decodable {
    let id: Int
    let responses: [String: Double]
}

private struct ParityExpectation: Decodable {
    let selectedID: Int?
    let score: Double?
    let excludedCandidateIDs: [Int]
}
