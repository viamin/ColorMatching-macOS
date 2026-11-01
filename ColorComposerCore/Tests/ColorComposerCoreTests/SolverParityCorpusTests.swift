import XCTest
@testable import ColorComposerCore

/// Solver parity against the golden-vector corpus published by the
/// `color_matching` Elixir backend (issue #39).
///
/// The corpus is generated upstream by `mix parity.generate` and committed
/// verbatim at `Tests/Fixtures/parity/v1/corpus.json`. Every scenario records
/// the palette response vectors, the target, the channel weights, the expected
/// per-candidate score (or exclusion), and the expected selection under the
/// upstream `selection: earliest-index-wins` policy.
///
/// Each scenario is replayed through `WeightedSquaredErrorScorer` (and through
/// `CompositionSolver`'s production fast path) with an exact-match requirement,
/// including floating-point equality for tie detection: corpus values are
/// dyadic rationals, so identical arithmetic order (canonical channel order,
/// `(c - t)² * w` terms) reproduces bit-for-bit on both sides.
///
/// Provenance and refresh procedure: `docs/solver-parity.md`.
final class SolverParityCorpusTests: XCTestCase {
    // MARK: Corpus wire model

    private enum CorpusScore: Equatable, Codable {
        case value(Double)
        case excluded

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                self = .value(number)
            } else if let text = try? container.decode(String.self), text == "excluded" {
                self = .excluded
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: #"Score must be a number or the string "excluded"."#
                )
            }
        }
    }

    private struct CorpusCandidate: Codable {
        let index: Int?
        let hexColor: String?
        let channels: [String: Double]

        enum CodingKeys: String, CodingKey {
            case index
            case hexColor = "hex_color"
            case channels
        }
    }

    private struct CorpusScoreEntry: Codable {
        let index: Int
        let score: CorpusScore
    }

    private struct CorpusExpected: Codable {
        let error: Double?
        let scores: [CorpusScoreEntry]
        let selectedHexColor: String?
        let selectedIndex: Int?
        let tieBroke: Bool?
        let tiedIndices: [Int]

        enum CodingKeys: String, CodingKey {
            case error
            case scores
            case selectedHexColor = "selected_hex_color"
            case selectedIndex = "selected_index"
            case tieBroke = "tie_broke"
            case tiedIndices = "tied_indices"
        }
    }

    private struct CorpusScenario: Codable {
        let id: String
        let description: String
        let palette: [CorpusCandidate]
        let target: CorpusCandidate
        let weights: [String: Double]
        let expected: CorpusExpected
    }

    private struct ParityCorpus: Codable {
        let algorithmVersion: Int
        let lightSources: [String]
        let missingPolicy: String
        let scorer: String
        let selection: String
        let scenarios: [CorpusScenario]

        enum CodingKeys: String, CodingKey {
            case algorithmVersion = "algorithm_version"
            case lightSources = "light_sources"
            case missingPolicy = "missing_policy"
            case scorer
            case selection
            case scenarios
        }
    }

    // MARK: Fixture loading and corpus → domain conversion

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ColorComposerCoreTests/
            .deletingLastPathComponent() // Tests/
            .appendingPathComponent("Fixtures/parity/v1/corpus.json")
        let data = try Data(contentsOf: fixtureURL)
        return try JSONDecoder().decode(ParityCorpus.self, from: data)
    }

    /// Canonical brightness vector for a corpus candidate. Unknown light-source
    /// keys are dropped — the same policy as `PaletteColorDTO.toDomain()`.
    private func brightness(for candidate: CorpusCandidate) -> [LightingCondition: Double] {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in candidate.channels {
            if let condition = LightingCondition(rawValue: key) {
                brightness[condition] = value
            }
        }
        return brightness
    }

    /// Corpus weights mapped onto `ChannelWeights`. Unknown light-source keys
    /// (e.g. `ultraviolet`) are ignored, mirroring how wire weights reach the
    /// app today.
    private func channelWeights(for scenario: CorpusScenario) -> ChannelWeights {
        var weights = ChannelWeights()
        for (key, value) in scenario.weights {
            switch key {
            case LightingCondition.white.rawValue: weights.white = value
            case LightingCondition.red.rawValue: weights.red = value
            case LightingCondition.green.rawValue: weights.green = value
            case LightingCondition.blue.rawValue: weights.blue = value
            case LightingCondition.lps.rawValue: weights.lps = value
            default: continue
            }
        }
        return weights
    }

    private func makePalette(
        for scenario: CorpusScenario
    ) throws -> [(index: Int, color: PaletteColor)] {
        var palette: [(index: Int, color: PaletteColor)] = []
        for entry in scenario.palette {
            let index = try XCTUnwrap(entry.index, "\(scenario.id): palette entry without an index")
            let hex = try XCTUnwrap(entry.hexColor, "\(scenario.id): palette entry \(index) without a hex color")
            let rgb = try XCTUnwrap(RGBColor(hex: hex), "\(scenario.id): unparseable hex \(hex)")
            let responses = brightness(for: entry).mapValues { IlluminationResponse(brightness: $0) }
            palette.append((index, PaletteColor(id: index, hex: hex, rgb: rgb, responses: responses)))
        }
        return palette
    }

    // MARK: Corpus metadata

    func testCorpusMetadataMatchesClientContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1, "corpus algorithm_version this test does not know")
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
        XCTAssertGreaterThanOrEqual(corpus.scenarios.count, 12, "expected the v1 scenario set")
    }

    /// The corpus must keep covering the parity risks it was written for:
    /// exact ties, missing-measurement exclusions, zero-weight channels, and a
    /// no-selection case.
    func testCorpusCoversRequiredParityRisks() throws {
        let corpus = try loadCorpus()
        let ids = Set(corpus.scenarios.map(\.id))

        let requiredScenarios = [
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
        for required in requiredScenarios {
            XCTAssertTrue(ids.contains(required), "corpus is missing scenario \(required)")
        }

        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true }, "no tie-break scenario")
        XCTAssertTrue(
            corpus.scenarios.contains { $0.expected.selectedIndex == nil },
            "no no-selection scenario"
        )
        XCTAssertTrue(
            corpus.scenarios.contains { scenario in
                scenario.expected.scores.contains { $0.score == .excluded }
            },
            "no exclusion scenario"
        )
    }

    // MARK: Scorer parity — per-candidate scores and exclusions

    func testScorerMatchesCorpusScoresExactly() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let weights = channelWeights(for: scenario)
            let target = TargetResponseVector(brightness(for: scenario.target))
            let palette = try makePalette(for: scenario)

            for (index, color) in palette {
                let expected = scenario.expected.scores.first { $0.index == index }
                let actual = scorer.score(candidate: color, target: target, weights: weights)

                switch (actual, expected?.score) {
                case (.score(let value), .value(let expectedValue)):
                    XCTAssertEqual(
                        value,
                        expectedValue,
                        "\(scenario.id) candidate \(index): score must match bit-for-bit"
                    )
                case (.excluded, .excluded):
                    continue
                case (.score, .excluded), (.score, nil):
                    XCTFail("\(scenario.id) candidate \(index): expected exclusion but received a score")
                case (.excluded, .value), (.excluded, nil):
                    XCTFail("\(scenario.id) candidate \(index): expected a score but was excluded")
                }
            }
        }
    }

    // MARK: Scorer parity — selection, ties, earliest-index-wins

    func testScorerSelectionMatchesCorpusIncludingTies() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let weights = channelWeights(for: scenario)
            let target = TargetResponseVector(brightness(for: scenario.target))
            let palette = try makePalette(for: scenario)

            var ranked: [(index: Int, score: Double)] = []
            for (index, color) in palette {
                if case .score(let value) = scorer.score(candidate: color, target: target, weights: weights) {
                    ranked.append((index, value))
                }
            }

            guard let best = ranked.map(\.score).min() else {
                XCTAssertNil(scenario.expected.selectedIndex, "\(scenario.id): expected no selection")
                XCTAssertTrue(scenario.expected.tiedIndices.isEmpty, "\(scenario.id): tied_indices should be empty")
                continue
            }

            let tied = ranked.filter { $0.score == best }
            let selected = tied.map(\.index).min()!

            XCTAssertEqual(selected, scenario.expected.selectedIndex, "\(scenario.id): selected index")
            XCTAssertEqual(
                palette.first { $0.index == selected }?.color.hex,
                scenario.expected.selectedHexColor,
                "\(scenario.id): selected hex color"
            )
            let expectedError = try XCTUnwrap(scenario.expected.error, "\(scenario.id): expected error")
            XCTAssertEqual(best, expectedError, "\(scenario.id): winning error")
            XCTAssertEqual(tied.map(\.index).sorted(), scenario.expected.tiedIndices, "\(scenario.id): tied indices")
            let expectedTieBroke = try XCTUnwrap(scenario.expected.tieBroke, "\(scenario.id): tie_broke")
            XCTAssertEqual(tied.count > 1, expectedTieBroke, "\(scenario.id): tie_broke")
        }
    }

    // MARK: Solver parity — production fast path via 1×1 grids

    /// Replays every fully-measured-target scenario through `CompositionSolver`
    /// — the code path the app actually runs — requiring the same selection,
    /// error, exclusion count, and tie behavior as the corpus.
    func testSolverFastPathMatchesCorpusSelection() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            let weights = channelWeights(for: scenario)
            let targetBrightness = brightness(for: scenario.target)

            // A target missing a positive-weight channel cannot be expressed
            // through the solver: source grids always define every active
            // channel. That case is covered at the scorer level above.
            let active = weights.activeConditions
            guard active.allSatisfy({ targetBrightness[$0] != nil }) else { continue }

            let palette = try makePalette(for: scenario).map(\.color)
            let sourceGrids = Dictionary(
                uniqueKeysWithValues: active.map { condition in
                    (condition, BrightnessGrid(width: 1, height: 1, values: [targetBrightness[condition]!]))
                }
            )

            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: sourceGrids,
                weights: weights
            )

            if let selectedIndex = scenario.expected.selectedIndex {
                XCTAssertEqual(result.colorIndex(x: 0, y: 0), selectedIndex, "\(scenario.id): solver index")
                let expectedError = try XCTUnwrap(scenario.expected.error, "\(scenario.id): expected error")
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, "\(scenario.id): solver error")
            } else {
                XCTAssertNil(result.colorIndex(x: 0, y: 0), "\(scenario.id): expected no selection")
                XCTAssertEqual(result.error(x: 0, y: 0), .infinity, "\(scenario.id): unselected cell error")
            }

            let excludedCount = scenario.expected.scores.filter { $0.score == .excluded }.count
            XCTAssertEqual(result.excludedCandidateCount, excludedCount, "\(scenario.id): excluded count")
        }
    }
}
