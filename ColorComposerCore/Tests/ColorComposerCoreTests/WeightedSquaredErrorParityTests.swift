import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testSelectionsMatchCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertEqual(corpus.upstream.repository, "viamin/color_matching")
        XCTAssertEqual(corpus.upstream.pullRequest, 111)
        XCTAssertFalse(corpus.cases.isEmpty)

        for parityCase in corpus.cases {
            XCTAssertEqual(
                selectCandidate(in: parityCase),
                parityCase.expectedSelectedID,
                "Parity case: \(parityCase.id)"
            )
        }
    }

    private func selectCandidate(in parityCase: ParityCase) -> Int? {
        let scorer = WeightedSquaredErrorScorer()
        let target = TargetResponseVector(parityCase.target.conditions)
        let weights = ChannelWeights(values: parityCase.weights.conditions)
        var best: (id: Int, score: Double)?

        for parityCandidate in parityCase.candidates {
            let candidate = parityCandidate.paletteColor
            guard case let .score(score) = scorer.score(candidate: candidate, target: target, weights: weights) else {
                continue
            }
            if best.map({ score < $0.score }) ?? true {
                best = (candidate.id, score)
            }
        }
        return best?.id
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixture = testFile
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity_corpus.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }
}

private struct ParityCorpus: Decodable {
    let schemaVersion: Int
    let upstream: UpstreamCorpus
    let cases: [ParityCase]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case upstream, cases
    }
}

private struct UpstreamCorpus: Decodable {
    let repository: String
    let pullRequest: Int

    private enum CodingKeys: String, CodingKey {
        case repository
        case pullRequest = "pull_request"
    }
}

private struct ParityCase: Decodable {
    let id: String
    let target: ConditionValues
    let weights: ConditionValues
    let candidates: [ParityCandidate]
    let expectedSelectedID: Int?

    private enum CodingKeys: String, CodingKey {
        case id, target, weights, candidates
        case expectedSelectedID = "expected_selected_id"
    }
}

private struct ParityCandidate: Decodable {
    let id: Int
    let responses: ConditionValues

    var paletteColor: PaletteColor {
        PaletteColor(
            id: id,
            hex: "#000000",
            rgb: RGBColor(hex: "#000000")!,
            responses: responses.conditions.mapValues(IlluminationResponse.init(brightness:))
        )
    }
}

private struct ConditionValues: Decodable {
    let values: [String: Double]

    init(from decoder: Decoder) throws {
        values = try [String: Double](from: decoder)
    }

    var conditions: [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { name, value in
            LightingCondition(rawValue: name).map { ($0, value) }
        })
    }
}

private extension ChannelWeights {
    init(values: [LightingCondition: Double]) {
        self.init(
            white: values[.white] ?? 0,
            red: values[.red] ?? 0,
            green: values[.green] ?? 0,
            blue: values[.blue] ?? 0,
            lps: values[.lps] ?? 0
        )
    }
}
