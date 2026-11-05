import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testSelectionsMatchTheCommittedParityCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertEqual(corpus.upstream.repository, "viamin/color_matching")
        XCTAssertEqual(corpus.upstream.pullRequest, 111)
        XCTAssertFalse(corpus.cases.isEmpty)

        for testCase in corpus.cases {
            let palette = testCase.candidates.map(makeColor)
            let sourceGrids = testCase.target.reduce(into: [LightingCondition: BrightnessGrid]()) {
                $0[condition(named: $1.key)] = BrightnessGrid(width: 1, height: 1, values: [$1.value])
            }
            let result = try CompositionSolver(scorer: WeightedSquaredErrorScorer()).solve(
                palette: palette,
                sourceGrids: sourceGrids,
                weights: weights(from: testCase.weights)
            )

            let selectedID = result.colorIndex(x: 0, y: 0).map { palette[$0].id }
            XCTAssertEqual(selectedID, testCase.expected.colorID, testCase.name)

            if let expectedScore = testCase.expected.score {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedScore, accuracy: 1e-12, testCase.name)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, testCase.name)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity_corpus.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: url))
    }

    private func makeColor(_ candidate: ParityCorpus.Candidate) -> PaletteColor {
        let responses = candidate.responses.reduce(into: [LightingCondition: IlluminationResponse]()) {
            $0[condition(named: $1.key)] = IlluminationResponse(brightness: $1.value)
        }
        return PaletteColor(id: candidate.id, hex: "#000000", rgb: RGBColor(hex: "#000000")!, responses: responses)
    }

    private func condition(named name: String) -> LightingCondition {
        guard let condition = LightingCondition(rawValue: name) else {
            fatalError("Unknown lighting condition in parity corpus: \(name)")
        }
        return condition
    }

    private func weights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }
}

private struct ParityCorpus: Decodable {
    let schemaVersion: Int
    let upstream: Upstream
    let cases: [Case]

    struct Upstream: Decodable {
        let repository: String
        let pullRequest: Int
    }

    struct Case: Decodable {
        let name: String
        let weights: [String: Double]
        let target: [String: Double]
        let candidates: [Candidate]
        let expected: Expected
    }

    struct Candidate: Decodable {
        let id: Int
        let responses: [String: Double]
    }

    struct Expected: Decodable {
        let colorID: Int?
        let score: Double?
    }
}
