import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testSelectionsMatchCommittedColorMatchingParityCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.source, "https://github.com/viamin/color_matching/pull/111")
        XCTAssertFalse(corpus.cases.isEmpty, "The committed parity corpus must not be empty.")

        for fixture in corpus.cases {
            let result = try CompositionSolver().solve(
                palette: fixture.candidates.map(makePaletteColor),
                sourceGrids: fixture.target.mapValues { BrightnessGrid(width: 1, height: 1, values: [$0]) },
                weights: fixture.weights.channelWeights
            )

            let winner = result.colorIndex(x: 0, y: 0).map { fixture.candidates[$0].id }
            XCTAssertEqual(winner, fixture.expected.winnerID, fixture.id)
            XCTAssertEqual(result.excludedCandidateCount, fixture.expected.excludedCandidateCount ?? 0, fixture.id)

            if let expectedScore = fixture.expected.score {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedScore, accuracy: 1e-12, fixture.id)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, fixture.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }

    private func makePaletteColor(_ fixture: CandidateFixture) -> PaletteColor {
        PaletteColor(
            id: fixture.id,
            hex: "#000000",
            rgb: RGBColor(hex: "#000000")!,
            responses: fixture.responses.mapValues { IlluminationResponse(brightness: $0) }
        )
    }
}

private struct ParityCorpus: Decodable {
    let source: String
    let cases: [ParityFixture]
}

private struct ParityFixture: Decodable {
    let id: String
    let weights: FixtureChannelValues
    let target: [LightingCondition: Double]
    let candidates: [CandidateFixture]
    let expected: ExpectedFixture
}

private struct CandidateFixture: Decodable {
    let id: Int
    let responses: [LightingCondition: Double]
}

private struct ExpectedFixture: Decodable {
    let winnerID: Int?
    let score: Double?
    let excludedCandidateCount: Int?
}

private struct FixtureChannelValues: Decodable {
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
