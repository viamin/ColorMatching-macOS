import Foundation
import XCTest
@testable import ColorComposerCore

/// Solver parity against the committed golden-vector corpus published by the
/// `color_matching` server (viamin/color_matching#111, merged as PR #112).
///
/// The corpus is a byte-identical copy of upstream `priv/parity/v1/corpus.json`
/// (see `docs/parity-corpus.md` for provenance and the refresh procedure). Each
/// scenario carries a palette of candidates with measured channel vectors, a
/// target vector, per-channel weights, and the selection the *Elixir*
/// `ColorMatching.WeightedSquaredError` solver produced — including designed
/// tie, exclusion, zero-weight, and unknown-weight cases.
///
/// This suite replays every scenario through `WeightedSquaredErrorScorer` and
/// the earliest-wins selection of `CompositionSolver` and asserts **exact**
/// agreement. Corpus floats are dyadic rationals (exact in IEEE-754 doubles)
/// and both implementations accumulate in canonical channel order, so exact
/// equality is meaningful: any divergence in tie-breaking, exclusion policy,
/// or weight handling is a parity failure.
final class SolverParityCorpusTests: XCTestCase {
    private let scorer = WeightedSquaredErrorScorer()

    // MARK: - Corpus wire model

    struct ParityCorpus: Codable {
        let algorithmVersion: Int
        let lightSources: [String]
        let missingPolicy: String
        let scorer: String
        let selection: String
        let scenarios: [ParityScenario]
    }

    struct ParityScenario: Codable {
        let id: String
        let description: String
        let palette: [ParityCandidate]
        let target: ParityVector
        let weights: [String: Double]
        let expected: ParityExpectation
    }

    struct ParityCandidate: Codable {
        let index: Int
        let hexColor: String
        let channels: [String: Double]
    }

    struct ParityVector: Codable {
        let index: Int?
        let hexColor: String?
        let channels: [String: Double]
    }

    struct ParityExpectation: Codable {
        let scores: [ParityExpectedScore]
        let selectedIndex: Int?
        let selectedHexColor: String?
        let error: Double?
        let tieBroke: Bool?
        let tiedIndices: [Int]
    }

    struct ParityExpectedScore: Codable {
        let index: Int
        let score: ParityScore
    }

    /// A score is either a finite number or the literal string `"excluded"`.
    enum ParityScore: Equatable {
        case value(Double)
        case excluded
    }

    // MARK: - Corpus replay

    func testSolverParityWithCommittedCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertGreaterThanOrEqual(corpus.scenarios.count, 12, "corpus scenario set shrank")
        for scenario in corpus.scenarios {
            assertScenarioReplaysExactly(scenario)
        }
    }

    func testCorpusMetadataPinsAlgorithmAndPolicy() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        // Corpus light sources must map 1:1 onto the client's conditions.
        XCTAssertEqual(LightingCondition.allCases.map(\.rawValue), corpus.lightSources)
    }

    /// Guards that the corpus keeps covering the parity dimensions the issue
    /// calls out: ties (including multi-way), missing-measurement exclusion,
    /// zero-weight channels, and unknown light sources in the weights map.
    func testCorpusCoversTieExclusionAndWeightDimensions() throws {
        let corpus = try loadCorpus()
        let ids = Set(corpus.scenarios.map(\.id))

        XCTAssertTrue(ids.contains("distinct-errors"))
        XCTAssertGreaterThanOrEqual(ids.filter { $0.hasPrefix("tie-") }.count, 3)
        XCTAssertTrue(ids.contains("missing-candidate-excluded"))
        XCTAssertTrue(ids.contains("missing-target-excluded"))
        XCTAssertTrue(ids.contains("all-excluded"))
        XCTAssertTrue(ids.contains("zero-weight-channel-missing"))
        XCTAssertTrue(ids.contains("unknown-weight-ignored"))

        let tieScenarios = corpus.scenarios.filter { $0.expected.tieBroke == true }
        XCTAssertGreaterThanOrEqual(tieScenarios.count, 3)
        XCTAssertTrue(tieScenarios.contains { $0.expected.tiedIndices.count >= 3 })

        let noSelection = corpus.scenarios.filter { $0.expected.selectedIndex == nil }
        XCTAssertGreaterThanOrEqual(noSelection.count, 2)
    }

    // MARK: - Per-scenario assertions

    private func assertScenarioReplaysExactly(_ scenario: ParityScenario) {
        let weights = Self.channelWeights(from: scenario.weights)
        let palette = Self.palette(from: scenario)
        let targetVector = Self.targetVector(from: scenario.target)

        // 1. Per-candidate scores match exactly (numbers bit-for-bit,
        //    exclusions as `.excluded`).
        var computedScores: [Int: ScorerResult] = [:]
        for color in palette {
            computedScores[color.id] = scorer.score(candidate: color, target: targetVector, weights: weights)
        }
        XCTAssertEqual(
            Set(computedScores.keys),
            Set(scenario.expected.scores.map(\.index)),
            "\(scenario.id): scored candidate set differs from corpus"
        )
        for expected in scenario.expected.scores {
            let result = computedScores[expected.index]
            switch (result, expected.score) {
            case (.some(.score(let value)), .value(let expectedValue)):
                XCTAssertEqual(
                    value, expectedValue,
                    "\(scenario.id): candidate \(expected.index) score mismatch"
                )
            case (.some(.excluded), .excluded):
                break
            default:
                XCTFail(
                    "\(scenario.id): candidate \(expected.index) expected \(expected.score), got \(String(describing: result))"
                )
            }
        }

        // 2. Earliest-index-wins selection derived from the real scores.
        let rankable = computedScores.compactMap { index, result -> (index: Int, score: Double)? in
            guard case .score(let value) = result else { return nil }
            return (index, value)
        }
        let expected = scenario.expected
        if rankable.isEmpty {
            XCTAssertNil(expected.selectedIndex, "\(scenario.id): expected a selection but nothing rankable")
            XCTAssertNil(expected.error, "\(scenario.id): expected error but nothing rankable")
            XCTAssertNil(expected.tieBroke, "\(scenario.id): tie evidence should be null when nothing rankable")
            XCTAssertTrue(expected.tiedIndices.isEmpty, "\(scenario.id): tied indices should be empty")
        } else {
            guard let minScore = rankable.map(\.score).min() else {
                return XCTFail("\(scenario.id): rankable candidates but no minimum score")
            }
            let tiedIndices = rankable.filter { $0.score == minScore }.map(\.index).sorted()
            let selected = tiedIndices.first

            XCTAssertEqual(selected, expected.selectedIndex, "\(scenario.id): selected index mismatch")
            XCTAssertEqual(tiedIndices, expected.tiedIndices, "\(scenario.id): tied index set mismatch")
            XCTAssertEqual(tiedIndices.count > 1, expected.tieBroke == true, "\(scenario.id): tie_broke mismatch")
            if let selected, let expectedError = expected.error {
                XCTAssertEqual(
                    rankable.first { $0.index == selected }?.score, expectedError,
                    "\(scenario.id): winner error mismatch"
                )
            }
            if let selected, let selectedHex = expected.selectedHexColor {
                XCTAssertEqual(
                    palette.first { $0.id == selected }?.hex, selectedHex,
                    "\(scenario.id): selected hex mismatch"
                )
            }
        }

        // 3. End-to-end through CompositionSolver with a 1×1 target grid per
        //    active channel — exercises the real selection path (including
        //    earliest-wins tie-breaking and the excluded-candidate count).
        let activeConditions = weights.activeConditions
        let targetComplete = activeConditions.allSatisfy { targetVector.value(for: $0) != nil }
        if !targetComplete {
            // A missing positive-weight channel on the *target* cannot be
            // expressed as source grids; the scorer-level assertions above
            // cover exactly this exclusion policy.
            XCTAssertNil(expected.selectedIndex, "\(scenario.id): incomplete target must yield no selection")
            return
        }

        var sourceGrids: [LightingCondition: BrightnessGrid] = [:]
        for condition in activeConditions {
            sourceGrids[condition] = BrightnessGrid(
                width: 1, height: 1,
                values: [targetVector.value(for: condition)!]
            )
        }

        let result: CompositionResult
        do {
            result = try CompositionSolver().solve(
                palette: palette, sourceGrids: sourceGrids, weights: weights
            )
        } catch {
            return XCTFail("\(scenario.id): solver threw \(error)")
        }

        XCTAssertEqual(
            result.colorIndex(x: 0, y: 0), expected.selectedIndex,
            "\(scenario.id): solver selection mismatch"
        )
        let excludedCount = scenario.expected.scores.filter { $0.score == .excluded }.count
        XCTAssertEqual(
            result.excludedCandidateCount, excludedCount,
            "\(scenario.id): excluded candidate count mismatch"
        )
        if let selectedIndex = expected.selectedIndex,
           let winner = palette.first(where: { $0.id == selectedIndex }) {
            XCTAssertEqual(
                result.error(x: 0, y: 0), expected.error,
                "\(scenario.id): solver per-cell error mismatch"
            )
            XCTAssertEqual(winner.hex, expected.selectedHexColor)
        } else {
            XCTAssertEqual(result.error(x: 0, y: 0), Double.infinity, "\(scenario.id): unmatched cell error")
        }
    }

    // MARK: - Corpus loading

    private func loadCorpus() throws -> ParityCorpus {
        let url = Self.fixturesDirectory.appendingPathComponent("corpus.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Parity corpus fixture missing at \(url.path). See docs/parity-corpus.md for the refresh procedure.")
            throw CocoaError(.fileNoSuchFile)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(ParityCorpus.self, from: try Data(contentsOf: url))
        } catch {
            XCTFail("Parity corpus fixture is not decodable: \(error)")
            throw error
        }
    }

    private static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ParityCorpus/v1", isDirectory: true)
    }

    // MARK: - Corpus → domain mapping

    /// Weight keys name light sources; anything outside
    /// `LightingCondition.allCases` (e.g. `ultraviolet`) is ignored — the
    /// corpus `unknown-weight-ignored` scenario pins that policy.
    private static func channelWeights(from raw: [String: Double]) -> ChannelWeights {
        var weights = ChannelWeights()
        for (name, value) in raw {
            switch LightingCondition(rawValue: name) {
            case .white: weights.white = value
            case .red: weights.red = value
            case .green: weights.green = value
            case .blue: weights.blue = value
            case .lps: weights.lps = value
            case nil: break
            }
        }
        return weights
    }

    private static func palette(from scenario: ParityScenario) -> [PaletteColor] {
        scenario.palette
            .sorted { $0.index < $1.index }
            .map { candidate in
                PaletteColor(
                    id: candidate.index,
                    hex: candidate.hexColor,
                    rgb: RGBColor(hex: candidate.hexColor)!,
                    responses: candidate.channels.reduce(
                        into: [LightingCondition: IlluminationResponse]()
                    ) { responses, entry in
                        if let condition = LightingCondition(rawValue: entry.key) {
                            responses[condition] = IlluminationResponse(brightness: entry.value)
                        }
                    }
                )
            }
    }

    private static func targetVector(from target: ParityVector) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (name, value) in target.channels {
            if let condition = LightingCondition(rawValue: name) {
                brightness[condition] = value
            }
        }
        return TargetResponseVector(brightness)
    }
}

extension SolverParityCorpusTests.ParityScore: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else if let literal = try? container.decode(String.self), literal == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "corpus score must be a number or the literal \"excluded\""
            )
        }
    }
}
