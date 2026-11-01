import Foundation
import XCTest
@testable import ColorComposerCore

/// Solver parity against the golden-vector corpus produced by the
/// `color_matching` server.
///
/// The corpus is the parity contract shared with the Elixir solver
/// (`ColorMatching.WeightedSquaredError` + `IllumitantMatching.best_match/4`,
/// see viamin/color_matching PR #111): any divergence in missing-measurement
/// exclusion, tie-breaking, or channel weighting between
/// `WeightedSquaredErrorScorer` and the server shows up here as a mismatch.
///
/// The fixture is mirrored byte-for-byte from the server repository
/// (`priv/parity/v{n}/corpus.json`) into `Fixtures/ParityCorpus/v{n}/`;
/// see `docs/solver-parity-corpus.md` for how to refresh it. The newest
/// versioned fixture directory is replayed, and its `algorithm_version` must
/// equal the semantics this scorer implements — a bump means the server
/// changed scoring semantics and the scorer must be updated before the
/// expectation below is.
final class SolverParityCorpusTests: XCTestCase {
    /// Algorithm version of the scorer/selection semantics implemented by
    /// `WeightedSquaredErrorScorer` + the earliest-wins selection below.
    private static let implementedAlgorithmVersion = 1

    private static let expectedScenarioIDs = [
        "distinct-errors",
        "tie-symmetric-around-target",
        "tie-duplicate-vectors",
        "tie-three-way-on-lps",
        "missing-candidate-excluded",
        "missing-target-excluded",
        "zero-weight-channel-missing",
        "all-excluded",
        "single-channel-lps",
        "exact-match-zero-error",
        "unknown-weight-ignored",
        "mixed-large-palette"
    ]

    // MARK: - Corpus fixture contract

    /// Mirrors the server's own `ColorMatching.Parity.CorpusTest` fixture
    /// checks: the corpus must be stamped with the semantics it captures.
    func testCorpusStampsMatchImplementedSolverSemantics() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(
            corpus.algorithm_version,
            Self.implementedAlgorithmVersion,
            "corpus algorithm_version changed; refresh the fixture and confirm "
                + "WeightedSquaredErrorScorer matches the new server semantics "
                + "before bumping implementedAlgorithmVersion"
        )
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missing_policy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.light_sources, ["white", "red", "green", "blue", "lps"])
    }

    /// A truncated or partially refreshed mirror must fail loudly, not
    /// silently narrow the parity surface.
    func testCorpusContainsTheFullUpstreamScenarioSet() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(
            Set(corpus.scenarios.map(\.id)),
            Set(Self.expectedScenarioIDs),
            "committed corpus scenario set differs from the upstream corpus"
        )
    }

    /// The corpus must keep the coverage it exists for: intentional ties and
    /// no-selection (all-excluded) scenarios.
    func testCorpusIncludesTieAndNullSelectionScenarios() throws {
        let corpus = try loadCorpus()

        XCTAssertGreaterThanOrEqual(corpus.scenarios.filter { $0.expected.tie_broke == true }.count, 1)
        XCTAssertGreaterThanOrEqual(
            corpus.scenarios.filter { $0.expected.selected_index == nil }.count,
            1
        )
    }

    /// Unknown light-source weight keys are ignored by the Elixir scorer
    /// (`filter_weights/1`); the corpus pins this with a scenario whose
    /// weights carry `ultraviolet: 3.0` yet whose errors are identical to the
    /// same scenario without it.
    func testUnknownWeightSourcesAreIgnored() throws {
        let corpus = try loadCorpus()
        let plain = try XCTUnwrap(corpus.scenarios.first { $0.id == "distinct-errors" })
        let unknown = try XCTUnwrap(corpus.scenarios.first { $0.id == "unknown-weight-ignored" })

        XCTAssertTrue(unknown.weights.keys.contains("ultraviolet"))
        XCTAssertEqual(unknown.expected.scores, plain.expected.scores)
    }

    // MARK: - Scenario replay

    /// Replays every scenario through `WeightedSquaredErrorScorer` and the
    /// earliest-wins selection and asserts exact agreement: per-candidate
    /// scores (exact doubles, not approximate), the selected candidate, the
    /// selection error, and the tie evidence.
    ///
    /// Exact equality is deliberate, mirroring the server test's `==`: every
    /// corpus value is a dyadic rational (small sums of k/2ⁿ products), so a
    /// faithful scorer reproduces the server's doubles bit-for-bit and any
    /// floating-point drift is itself a parity bug.
    func testReplaysEveryScenarioWithExactAgreement() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            try assertReplay(scenario)
        }
    }

    /// The tie cases the issue calls out: when several candidates share the
    /// minimum error exactly, the earliest index must win.
    func testTieScenariosSelectEarliestTiedIndex() throws {
        let corpus = try loadCorpus()
        let tiedScenarios = corpus.scenarios.filter { $0.expected.tie_broke == true }

        XCTAssertGreaterThanOrEqual(tiedScenarios.count, 1, "corpus lost its tie scenarios")

        for scenario in tiedScenarios {
            XCTAssertEqual(
                scenario.expected.selected_index,
                scenario.expected.tied_indices.first,
                "\(scenario.id): selection must be the earliest tied index"
            )
            XCTAssertGreaterThanOrEqual(scenario.expected.tied_indices.count, 2)
        }
    }

    // MARK: - Replay mechanics

    /// Asserts one scenario: scores, selection, error, and tie evidence all
    /// match the corpus expectations exactly. Kept whole — the four checks
    /// read as one parity verdict and splitting them would only relocate the
    /// scenario plumbing.
    private func assertReplay(_ scenario: Scenario) throws {
        let scored = scoreAll(scenario)
        let candidates = palette(scenario)
        let best = bestMatch(scored: scored)

        for entry in scenario.expected.scores {
            XCTAssertTrue(scored.indices.contains(entry.index), "\(scenario.id): score index \(entry.index) out of range")
            if scored.indices.contains(entry.index) {
                assertScore(scored[entry.index], matches: entry.score, scenario: scenario.id)
            }
        }
        XCTAssertEqual(scenario.expected.scores.count, scored.count, scenario.id)

        switch (best, scenario.expected.selected_index) {
        case (nil, nil):
            XCTAssertTrue(scenario.expected.tie_broke == nil, scenario.id)
            XCTAssertEqual(scenario.expected.tied_indices, [], scenario.id)
        case let (.some(selection), .some(expectedIndex)):
            XCTAssertEqual(selection.index, expectedIndex, scenario.id)
            XCTAssertTrue(candidates.indices.contains(expectedIndex), scenario.id)
            if candidates.indices.contains(expectedIndex) {
                XCTAssertEqual(candidates[expectedIndex].hex_color, scenario.expected.selected_hex_color, scenario.id)
            }
            let expectedError = try XCTUnwrap(scenario.expected.error, scenario.id)
            XCTAssertEqual(selection.score, expectedError, scenario.id)

            let tied = tiedIndices(scored: scored, at: selection.score)
            XCTAssertEqual(tied, scenario.expected.tied_indices, scenario.id)
            XCTAssertTrue(scenario.expected.tie_broke == (tied.count > 1), scenario.id)
            XCTAssertEqual(tied.first, .some(expectedIndex), scenario.id)
        case (.some, nil), (nil, .some):
            XCTFail("\(scenario.id): selection presence disagrees with corpus")
        }
    }

    /// Scores every palette candidate with `WeightedSquaredErrorScorer`.
    private func scoreAll(_ scenario: Scenario) -> [ScorerResult] {
        let scorer = WeightedSquaredErrorScorer()
        let target = targetVector(scenario.target)
        return palette(scenario).map {
            scorer.score(candidate: $0, target: target, weights: weights(scenario.weights))
        }
    }

    /// Mirrors `IlluminantMatching.best_match/4`: the lowest score wins and
    /// exact ties break to the earliest candidate index.
    private func bestMatch(scored: [ScorerResult]) -> (index: Int, score: Double)? {
        var best: (index: Int, score: Double)?
        for (index, result) in scored.enumerated() {
            guard case .score(let score) = result else { continue }
            if best == nil || score < best!.score {
                best = (index, score)
            }
        }
        return best
    }

    /// Ascending indices of every candidate whose score equals `error`
    /// exactly — the corpus's `tied_indices`.
    private func tiedIndices(scored: [ScorerResult], at error: Double) -> [Int] {
        scored.indices.compactMap { index in
            guard case .score(let score) = scored[index], score == error else { return nil }
            return index
        }
    }

    private func assertScore(
        _ result: ScorerResult,
        matches expected: CorpusScore,
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (result, expected) {
        case (.excluded, .excluded):
            return
        case (.score(let score), .value(let expectedValue)):
            XCTAssertEqual(score, expectedValue, "\(scenario): exact score parity", file: file, line: line)
        case (.score, .excluded):
            XCTFail("\(scenario): expected exclusion but the candidate was scorable", file: file, line: line)
        case (.excluded, .value):
            XCTFail("\(scenario): expected a score but the candidate was excluded", file: file, line: line)
        }
    }

    // MARK: - Corpus decoding and domain mapping

    private func loadCorpus(file: StaticString = #filePath, line: UInt = #line) throws -> Corpus {
        let url = try XCTUnwrap(Self.corpusFileURL(), file: file, line: line)
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }

    /// Newest `v<n>/corpus.json` beside this test file, mirroring the server's
    /// versioned `priv/parity/v{n}` layout. Resolved from `#filePath` (the
    /// checkout on disk), which survives both `swift test` and the generated
    /// Xcode project; the fixture is deliberately inside the test directory.
    private static func corpusFileURL() -> URL? {
        let fixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ParityCorpus", isDirectory: true)

        let versions = ((try? FileManager.default.contentsOfDirectory(
            at: fixtureRoot,
            includingPropertiesForKeys: nil
        )) ?? [])
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix("v")
                    && Int(name.dropFirst()) != nil
                    && FileManager.default.fileExists(atPath: url.appendingPathComponent("corpus.json").path)
            }
            .sorted { lhs, rhs in
                Int(lhs.lastPathComponent.dropFirst())! < Int(rhs.lastPathComponent.dropFirst())!
            }
        return versions.last?.appendingPathComponent("corpus.json")
    }

    /// Unknown weight keys (e.g. `ultraviolet`) are dropped, mirroring the
    /// Elixir `filter_weights/1`; absent channels weigh zero.
    private func weights(_ encoded: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: encoded["white"] ?? 0,
            red: encoded["red"] ?? 0,
            green: encoded["green"] ?? 0,
            blue: encoded["blue"] ?? 0,
            lps: encoded["lps"] ?? 0
        )
    }

    /// Channels absent from the entry are missing measurements (not zero
    /// brightness) — they simply have no key in the vector.
    private func targetVector(_ entry: CorpusEntry) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in entry.channels {
            if let condition = LightingCondition(rawValue: key) {
                brightness[condition] = value
            }
        }
        return TargetResponseVector(brightness)
    }

    private func palette(_ scenario: Scenario) -> [PaletteColor] {
        scenario.palette
            .sorted { ($0.index ?? -1) < ($1.index ?? -1) }
            .enumerated()
            .compactMap { position, entry in
                guard let rgb = RGBColor(hex: entry.hex_color) else { return nil }
                return PaletteColor(
                    id: entry.index ?? position,
                    hex: entry.hex_color,
                    rgb: rgb,
                    responses: entry.channels.reduce(into: [:]) { responses, pair in
                        guard let condition = LightingCondition(rawValue: pair.key) else { return }
                        responses[condition] = IlluminationResponse(brightness: pair.value)
                    }
                )
            }
    }
}

// MARK: - Wire shapes (mirrored from priv/parity/v{n}/corpus.json)

/// Field names intentionally keep the corpus's snake_case spelling so the
/// fixture decodes without key-conversion strategy games.
private struct Corpus: Decodable {
    let algorithm_version: Int
    let scorer: String
    let selection: String
    let missing_policy: String
    let light_sources: [String]
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let description: String
    let weights: [String: Double]
    let target: CorpusEntry
    let palette: [CorpusEntry]
    let expected: Expected
}

private struct CorpusEntry: Decodable {
    let index: Int?
    let hex_color: String
    let channels: [String: Double]
}

private struct Expected: Decodable {
    let scores: [ScoreEntry]
    let selected_index: Int?
    let selected_hex_color: String?
    let error: Double?
    let tie_broke: Bool?
    let tied_indices: [Int]
}

private struct ScoreEntry: Decodable, Equatable {
    let index: Int
    let score: CorpusScore
}

/// A per-candidate expectation: a finite score, or `"excluded"`.
private enum CorpusScore: Decodable, Equatable {
    case value(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else if let raw = try? container.decode(String.self), raw == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: #"expected a numeric score or "excluded""#
            )
        }
    }
}
