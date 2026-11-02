import Foundation
import XCTest
@testable import ColorComposerCore

/// Solver parity test target for issue #39: drives `CompositionSolver` with
/// its default `WeightedSquaredErrorScorer` against a corpus of
/// (weights, target, candidates) -> expected-selection cases and asserts the
/// selection matches exactly, including tie cases and exclusions.
///
/// `testVendoredCorpusMatchesScorerSelectionsExactly` loads the corpus
/// committed from viamin/color_matching#111. That corpus is not yet vendored
/// into this repo — the dependency (viamin/color_matching#111) had not
/// published it as of this PR — so the test fails with a diagnostic
/// explaining exactly what is missing and where to put it, rather than
/// silently skipping. This is the expected red-phase failure for this
/// acceptance criterion.
///
/// `testHarnessMatchesLocalSampleCorpus` exercises the same loader and
/// solving path against a small, hand-derived fixture committed alongside
/// this file (`Fixtures/solver_parity_corpus.sample.json`), so the harness
/// itself is proven correct independent of the upstream corpus's arrival.
final class SolverParityCorpusTests: XCTestCase {
    // MARK: - Corpus schema

    private struct ParityCorpus: Decodable {
        let cases: [ParityCase]
    }

    private struct ParityCase: Decodable {
        let name: String
        let weights: [String: Double]
        let target: [String: Double]
        let candidates: [ParityCandidate]
        let expectedSelectedId: Int?
        let expectedScore: Double?
        let tags: [String]?
    }

    private struct ParityCandidate: Decodable {
        let id: Int
        let responses: [String: Double]
    }

    // MARK: - Tests

    func testHarnessMatchesLocalSampleCorpus() throws {
        let corpus = try Self.loadCorpus(from: Self.fixtureURL("solver_parity_corpus.sample.json"))
        XCTAssertFalse(corpus.cases.isEmpty, "Sample corpus fixture should not be empty")
        try assertSelectionsMatch(corpus)
    }

    func testVendoredCorpusMatchesScorerSelectionsExactly() throws {
        let url = Self.fixtureURL("solver_parity_corpus.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("""
            The solver parity corpus from viamin/color_matching#111 is not vendored at \
            \(url.path). This corpus had not been published upstream as of this PR \
            (issue #39 depends on viamin/color_matching#111). Once it is published:
            1. Copy it to ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/solver_parity_corpus.json
               in the schema documented in docs/solver-parity-corpus.md.
            2. Re-run `swift test --filter SolverParityCorpusTests` — this test will then assert every
               case's expected selection (including documented tie and exclusion cases) against
               WeightedSquaredErrorScorer via CompositionSolver.
            """)
            return
        }
        let corpus = try Self.loadCorpus(from: url)
        try assertSelectionsMatch(corpus)
    }

    // MARK: - Harness

    private static func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    private static func loadCorpus(from url: URL) throws -> ParityCorpus {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: data)
    }

    private func assertSelectionsMatch(_ corpus: ParityCorpus) throws {
        for testCase in corpus.cases {
            let outcome = try solve(testCase)
            XCTAssertEqual(
                outcome.selectedId, testCase.expectedSelectedId,
                "case '\(testCase.name)' selected \(String(describing: outcome.selectedId)), " +
                "expected \(String(describing: testCase.expectedSelectedId))"
            )
            if let expectedScore = testCase.expectedScore {
                guard let score = outcome.score else {
                    XCTFail("case '\(testCase.name)' expected score \(expectedScore) but got no selection")
                    continue
                }
                XCTAssertEqual(
                    score, expectedScore, accuracy: 1e-9,
                    "case '\(testCase.name)' scored \(score), expected \(expectedScore)"
                )
            }
        }
    }

    /// Runs one corpus case through the real `CompositionSolver` +
    /// `WeightedSquaredErrorScorer` pipeline on a single 1x1 cell, so the
    /// corpus exercises the same selection and tie-break code path the app
    /// uses, not a parallel hand-rolled reimplementation.
    private func solve(_ testCase: ParityCase) throws -> (selectedId: Int?, score: Double?) {
        let weights = Self.channelWeights(from: testCase.weights)
        let activeConditions = weights.activeEntries.map(\.condition)

        var sourceGrids: [LightingCondition: BrightnessGrid] = [:]
        for condition in activeConditions {
            let value = testCase.target[condition.rawValue] ?? 0
            sourceGrids[condition] = BrightnessGrid(width: 1, height: 1, values: [value])
        }

        let palette = testCase.candidates.map(Self.paletteColor(from:))
        let result = try CompositionSolver(scorer: WeightedSquaredErrorScorer()).solve(
            palette: palette,
            sourceGrids: sourceGrids,
            weights: weights
        )

        guard let index = result.colorIndex(x: 0, y: 0) else { return (nil, nil) }
        return (palette[index].id, result.error(x: 0, y: 0))
    }

    private static func channelWeights(from dict: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: dict["white"] ?? 0,
            red: dict["red"] ?? 0,
            green: dict["green"] ?? 0,
            blue: dict["blue"] ?? 0,
            lps: dict["lps"] ?? 0
        )
    }

    private static func paletteColor(from candidate: ParityCandidate) -> PaletteColor {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, value) in candidate.responses {
            guard let condition = LightingCondition(rawValue: key) else { continue }
            responses[condition] = IlluminationResponse(brightness: value)
        }
        return PaletteColor(id: candidate.id, hex: "#000000", rgb: RGBColor(hex: "#000000")!, responses: responses)
    }
}
