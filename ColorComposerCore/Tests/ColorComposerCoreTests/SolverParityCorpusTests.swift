import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testCorpusIsVerifiedUpstreamSnapshot() throws {
        let upstream = try loadCorpus().upstream

        XCTAssertEqual(upstream.repository, "viamin/color_matching")
        XCTAssertEqual(upstream.pullRequest, 111)
        XCTAssertEqual(
            upstream.status,
            "verified",
            "Replace the provisional fixture with the exact corpus from viamin/color_matching#111."
        )
        XCTAssertFalse(upstream.revision.isEmpty, "Record the upstream corpus revision when refreshing the fixture.")
    }

    func testWeightedSquaredErrorSelectionsMatchParityCorpus() throws {
        for parityCase in try loadCorpus().cases {
            let weights = try makeWeights(parityCase.weights)
            let target = try makeTarget(parityCase)
            let excludedCandidateIDs = parityCase.candidates.compactMap { candidate in
                let result = WeightedSquaredErrorScorer().score(
                    candidate: makeColor(candidate), target: target, weights: weights
                )
                return result == .excluded ? candidate.id : nil
            }
            let result = try CompositionSolver().solve(
                palette: parityCase.candidates.map(makeColor),
                sourceGrids: try makeSourceGrids(parityCase),
                weights: weights
            )

            XCTAssertEqual(
                result.colorIndex(x: 0, y: 0).map { result.palette[$0].id },
                parityCase.expected.selectedId,
                "Case: \(parityCase.name)"
            )
            XCTAssertEqual(
                excludedCandidateIDs,
                parityCase.expected.excludedCandidateIds,
                "Case: \(parityCase.name)"
            )

            if let expectedScore = parityCase.expected.score {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedScore, accuracy: 1e-12, "Case: \(parityCase.name)")
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, "Case: \(parityCase.name)")
            }
        }
    }

    private func makeTarget(_ parityCase: ParityCase) throws -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (name, value) in parityCase.target {
            guard let condition = LightingCondition(rawValue: name) else {
                throw CorpusError.unknownCondition(name)
            }
            brightness[condition] = value
        }
        return TargetResponseVector(brightness)
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makeColor(_ candidate: ParityCandidate) -> PaletteColor {
        let responses = candidate.responses.reduce(into: [LightingCondition: IlluminationResponse]()) { result, entry in
            if let condition = LightingCondition(rawValue: entry.key) {
                result[condition] = IlluminationResponse(brightness: entry.value)
            }
        }
        return PaletteColor(id: candidate.id, hex: "#000000", rgb: RGBColor(hex: "#000000")!, responses: responses)
    }

    private func makeSourceGrids(_ parityCase: ParityCase) throws -> [LightingCondition: BrightnessGrid] {
        try parityCase.weights.reduce(into: [:]) { result, entry in
            guard entry.value > 0 else { return }
            guard let condition = LightingCondition(rawValue: entry.key), let target = parityCase.target[entry.key] else {
                throw CorpusError.invalidCase(parityCase.name)
            }
            result[condition] = BrightnessGrid(width: 1, height: 1, values: [target])
        }
    }

    private func makeWeights(_ weights: [String: Double]) throws -> ChannelWeights {
        for condition in weights.keys where LightingCondition(rawValue: condition) == nil {
            throw CorpusError.unknownCondition(condition)
        }
        return ChannelWeights(
            white: weights["white", default: 0],
            red: weights["red", default: 0],
            green: weights["green", default: 0],
            blue: weights["blue", default: 0],
            lps: weights["lps", default: 0]
        )
    }
}

private struct ParityCorpus: Decodable {
    let upstream: ParityUpstream
    let cases: [ParityCase]
}

private struct ParityUpstream: Decodable {
    let repository: String
    let pullRequest: Int
    let status: String
    let revision: String

    private enum CodingKeys: String, CodingKey {
        case repository
        case pullRequest = "pull_request"
        case status
        case revision
    }
}

private struct ParityCase: Decodable {
    let name: String
    let weights: [String: Double]
    let target: [String: Double]
    let candidates: [ParityCandidate]
    let expected: ParityExpected
}

private struct ParityCandidate: Decodable {
    let id: Int
    let responses: [String: Double]
}

private struct ParityExpected: Decodable {
    let selectedId: Int?
    let score: Double?
    let excludedCandidateIds: [Int]

    private enum CodingKeys: String, CodingKey {
        case selectedId = "selected_id"
        case score
        case excludedCandidateIds = "excluded_candidate_ids"
    }
}

private enum CorpusError: Error {
    case invalidCase(String)
    case unknownCondition(String)
}
