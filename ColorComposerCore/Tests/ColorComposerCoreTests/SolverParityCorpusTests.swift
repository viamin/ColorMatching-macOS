import Foundation
import XCTest
@testable import ColorComposerCore

/// Solver parity against the committed corpus.
///
/// The corpus (`Fixtures/solver_parity_corpus.json`, upstream
/// viamin/color_matching#111) pins `WeightedSquaredErrorScorer` — and the
/// production `CompositionSolver` selection path — to the Elixir
/// `WeightedSquaredError` / `IlluminantMatching.best_match` semantics:
/// exclusion of candidates missing a required measurement (missing is never
/// zero brightness), zero-weight channels ignored, earliest-candidate
/// tie-breaking, and exact expected selections and scores per case.
///
/// See `docs/solver-parity-corpus.md` for the format and how to refresh the
/// corpus from the upstream export.
final class SolverParityCorpusTests: XCTestCase {
    private let scorer = WeightedSquaredErrorScorer()

    // MARK: - Corpus integrity

    func testCorpusFileExistsAndDecodes() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.meta.format, "color_matching.solver_parity_corpus/1")
        XCTAssertFalse(corpus.cases.isEmpty, "parity corpus must contain at least one case")
    }

    func testCorpusCaseIDsAreUnique() throws {
        let corpus = try loadCorpus()

        let ids = corpus.cases.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "corpus case ids must be unique")
    }

    /// A corpus without tie, exclusion, and unmatched coverage cannot enforce
    /// the parts of the contract that are easiest to regress.
    func testCorpusCoversTiesExclusionsAndUnmatchedCases() throws {
        let corpus = try loadCorpus()

        XCTAssertFalse(corpus.cases.filter { $0.tie == true }.isEmpty, "corpus must include at least one tie case")
        XCTAssertFalse(corpus.cases.filter { !$0.expectedExcluded.isEmpty }.isEmpty, "corpus must include at least one exclusion case")
        XCTAssertFalse(corpus.cases.filter { $0.expectedSelection == nil }.isEmpty, "corpus must include at least one all-excluded (unmatched) case")
        XCTAssertTrue(
            corpus.cases.contains { entry in
                LightingCondition.all.allSatisfy { entry.weights.weight(for: $0) > 0 }
            },
            "corpus must include at least one case weighting all five channels"
        )
    }

    func testEveryCaseIsStructurallyValid() throws {
        let corpus = try loadCorpus()

        for entry in corpus.cases {
            let id = entry.id
            XCTAssertFalse(
                entry.weights.activeConditions.isEmpty,
                "case \(id): at least one channel must have weight > 0"
            )
            XCTAssertNoThrow(
                try makePalette(for: entry),
                "case \(id): every candidate hex must parse and every lighting key must be canonical"
            )
            XCTAssertNoThrow(
                try makeTarget(for: entry),
                "case \(id): every target lighting key must be canonical"
            )
            if let selection = entry.expectedSelection {
                XCTAssertTrue(
                    entry.candidates.indices.contains(selection),
                    "case \(id): expected_selection \(selection) is out of range"
                )
                if let selectedName = entry.expectedSelectedName {
                    XCTAssertEqual(
                        entry.candidates[selection].name, selectedName,
                        "case \(id): expected_selected_name disagrees with expected_selection"
                    )
                }
            }
        }
    }

    // MARK: - Parity: scorer-level selection

    /// Every corpus case must select the expected candidate using
    /// `WeightedSquaredErrorScorer` under lowest-score/earliest-wins policy —
    /// including exact ties and exclusions.
    func testScorerSelectionsMatchCorpusIncludingTies() throws {
        let corpus = try loadCorpus()

        for entry in corpus.cases {
            let id = entry.id
            let palette = try makePalette(for: entry)
            let target = try makeTarget(for: entry)

            let best = bestCandidate(palette, target: target, weights: entry.weights)
            XCTAssertEqual(best.index, entry.expectedSelection, "case \(id): selection")
            if let expected = entry.expectedScore {
                assertEqual(best.score, expected, accuracy: 1e-9, caseID: id)
            }

            let excluded = excludedIndices(palette, target: target, weights: entry.weights)
            XCTAssertEqual(Set(excluded), Set(entry.expectedExcluded), "case \(id): excluded candidates")
        }
    }

    // MARK: - Parity: production solver path

    /// The production `CompositionSolver` fast path must agree with the corpus:
    /// same selection, same per-cell error, and the same number of excluded
    /// candidates for a single-cell composition built from the case target.
    func testProductionSolverSelectionsMatchCorpus() throws {
        let corpus = try loadCorpus()

        for entry in corpus.cases {
            let id = entry.id
            let palette = try makePalette(for: entry)
            let target = try makeTarget(for: entry)
            let grids = target.brightness.mapValues { BrightnessGrid(width: 1, height: 1, values: [$0]) }

            let result = try CompositionSolver(scorer: WeightedSquaredErrorScorer()).solve(
                palette: palette,
                sourceGrids: grids,
                weights: entry.weights
            )

            XCTAssertEqual(result.colorIndex(x: 0, y: 0), entry.expectedSelection, "case \(id): solver selection")
            if let expected = entry.expectedScore {
                XCTAssertEqual(result.error(x: 0, y: 0), expected, accuracy: 1e-9, "case \(id): solver error")
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, "case \(id): unmatched cell must record infinite error")
            }
            XCTAssertEqual(
                result.excludedCandidateCount, entry.expectedExcluded.count,
                "case \(id): solver excluded-candidate count"
            )
        }
    }

    // MARK: - Loading

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("solver_parity_corpus.json")
        let data = try Data(contentsOf: fixture)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: data)
    }

    // MARK: - Case mapping

    private func makePalette(for entry: ParityCase) throws -> [PaletteColor] {
        try entry.candidates.enumerated().map { index, candidate in
            guard let rgb = RGBColor(hex: candidate.hex) else {
                throw CorpusFixtureError.invalidHex(candidate.hex, context: "candidate \(index) in \(entry.id)")
            }
            return PaletteColor(
                id: index,
                name: candidate.name,
                hex: candidate.hex,
                rgb: rgb,
                responses: try illuminate(candidate.responses, context: "candidate \(index) in \(entry.id)")
            )
        }
    }

    private func makeTarget(for entry: ParityCase) throws -> TargetResponseVector {
        TargetResponseVector(try illuminate(entry.target, context: "target in \(entry.id)"))
    }

    /// Maps raw response keys to conditions, rejecting any key outside the
    /// canonical lighting-condition set: a corpus with a typo'd condition must
    /// fail loudly instead of silently dropping the measurement.
    private func illuminate(_ raw: [String: Double], context: String) throws -> [LightingCondition: Double] {
        var mapped: [LightingCondition: Double] = [:]
        for (key, value) in raw {
            guard let condition = LightingCondition(rawValue: key) else {
                throw CorpusFixtureError.unknownLightingKey(key, context: context)
            }
            mapped[condition] = value
        }
        return mapped
    }

    // MARK: - Selection policy (mirrors CompositionSolver's documented policy)

    private func bestCandidate(
        _ palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> (index: Int?, score: Double?) {
        var bestIndex: Int?
        var bestScore = Double.infinity
        for (index, color) in palette.enumerated() {
            guard case .score(let score) = scorer.score(candidate: color, target: target, weights: weights) else {
                continue
            }
            if score < bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        return (bestIndex, bestIndex == nil ? nil : bestScore)
    }

    private func excludedIndices(
        _ palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> [Int] {
        palette.indices.filter {
            scorer.score(candidate: palette[$0], target: target, weights: weights) == .excluded
        }
    }

    private func assertEqual(
        _ actual: Double?,
        _ expected: Double,
        accuracy: Double,
        caseID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            return XCTFail("case \(caseID): expected score \(expected) but no candidate was selected", file: file, line: line)
        }
        XCTAssertEqual(actual, expected, accuracy: accuracy, "case \(caseID)", file: file, line: line)
    }
}

// MARK: - Corpus wire format

private struct ParityCorpus: Codable {
    struct Meta: Codable {
        let format: String
        let upstream: String?
        let origin: String?
        let notes: String?
    }

    let meta: Meta
    let cases: [ParityCase]
}

private struct ParityCase: Codable {
    let id: String
    let description: String?
    let tie: Bool?
    let weights: ChannelWeights
    let target: [String: Double]
    let candidates: [ParityCandidate]
    let expectedSelection: Int?
    let expectedSelectedName: String?
    let expectedScore: Double?
    let expectedExcluded: [Int]
}

private struct ParityCandidate: Codable {
    let name: String
    let hex: String
    let responses: [String: Double]
}

private enum CorpusFixtureError: Error, CustomStringConvertible {
    case unknownLightingKey(String, context: String)
    case invalidHex(String, context: String)

    var description: String {
        switch self {
        case .unknownLightingKey(let key, let context):
            return "non-canonical lighting key \"\(key)\" in \(context)"
        case .invalidHex(let hex, let context):
            return "unparseable hex \"\(hex)\" in \(context)"
        }
    }
}
