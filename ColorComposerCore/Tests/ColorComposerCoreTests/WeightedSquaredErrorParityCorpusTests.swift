import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testSelectionsMatchCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.formatVersion, 1)
        XCTAssertFalse(corpus.cases.isEmpty)

        for testCase in corpus.cases {
            let palette = try testCase.candidates.map(makePaletteColor)
            let target = TargetResponseVector(testCase.target)
            let weights = testCase.weights.channelWeights
            let excludedCandidateIDs = palette.compactMap { candidate -> Int? in
                guard case .excluded = WeightedSquaredErrorScorer().score(
                    candidate: candidate,
                    target: target,
                    weights: weights
                ) else { return nil }
                return candidate.id
            }
            let sourceGrids = try testCase.target.mapValues { BrightnessGrid(width: 1, height: 1, values: [$0]) }
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: sourceGrids,
                weights: weights
            )

            XCTAssertEqual(
                result.colorIndex(x: 0, y: 0).map { palette[$0].id },
                testCase.expected.candidateID,
                testCase.name
            )
            XCTAssertEqual(excludedCandidateIDs, testCase.expected.excludedCandidateIDs, testCase.name)
            XCTAssertEqual(result.excludedCandidateCount, excludedCandidateIDs.count, testCase.name)

            if let expectedScore = testCase.expected.score {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedScore, accuracy: 1e-12, testCase.name)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, testCase.name)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixture = testFile.deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makePaletteColor(_ candidate: ParityCandidate) throws -> PaletteColor {
        PaletteColor(
            id: candidate.id,
            hex: "#000000",
            rgb: try XCTUnwrap(RGBColor(hex: "#000000")),
            responses: candidate.responses.mapValues { IlluminationResponse(brightness: $0) }
        )
    }
}

private struct ParityCorpus: Decodable {
    let formatVersion: Int
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: ParityResponses
    let target: [LightingCondition: Double]
    let candidates: [ParityCandidate]
    let expected: ParityExpected
}

private struct ParityCandidate: Decodable {
    let id: Int
    let responses: [LightingCondition: Double]
}

private struct ParityExpected: Decodable {
    let candidateID: Int?
    let score: Double?
    let excludedCandidateIDs: [Int]
}

private struct ParityResponses: Decodable {
    let white: Double?
    let red: Double?
    let green: Double?
    let blue: Double?
    let lps: Double?

    var channelWeights: ChannelWeights {
        ChannelWeights(white: white ?? 0, red: red ?? 0, green: green ?? 0, blue: blue ?? 0, lps: lps ?? 0)
    }
}
