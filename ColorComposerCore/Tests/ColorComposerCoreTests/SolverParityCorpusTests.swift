import Foundation
import XCTest
@testable import ColorComposerCore

/// Solver parity harness: loads the committed corpus and asserts that
/// `WeightedSquaredErrorScorer` — through `CompositionSolver` selection —
/// reproduces the expected outputs exactly, including deterministic
/// earliest-palette-order tie-breaking, candidate exclusions, and weight
/// handling.
///
/// The corpus mirrors `ColorMatching.WeightedSquaredError` (and the
/// `IlluminantMatching.best_match/4` selection policy) in the Elixir
/// `color_matching` service. The seed corpus here is hand-computed from the
/// documented semantics; it is replaced in place by the generated corpus from
/// viamin/color_matching#111. See `docs/solver-parity-corpus.md` for the
/// format and refresh procedure.
final class SolverParityCorpusTests: XCTestCase {
    private enum CorpusError: Error, CustomStringConvertible {
        case unreadable(URL, underlying: String)
        case unknownCondition(String, caseID: String)
        case unknownScope(String, caseID: String)
        case unsupportedSchema(Int)
        case authoring(String)

        var description: String {
            switch self {
            case .unreadable(let url, let underlying):
                return "Parity corpus could not be loaded from \(url.path): \(underlying)"
            case .unknownCondition(let key, let caseID):
                return "Case \(caseID): unknown lighting condition key \"\(key)\""
            case .unknownScope(let scope, let caseID):
                return "Case \(caseID): unknown scope \"\(scope)\""
            case .unsupportedSchema(let version):
                return "Parity corpus schema_version \(version) is not supported by this harness (expected \(SolverParityCorpusTests.supportedSchemaVersion))"
            case .authoring(let detail):
                return "Parity corpus authoring error: \(detail)"
            }
        }
    }

    private struct Corpus: Codable {
        struct Case: Codable {
            struct PaletteEntry: Codable {
                let id: Int
                let hex: String
                let name: String?
                let responses: [String: Double]
            }

            struct Expected: Codable {
                let selectedColorId: Int?
                let score: Double?
                let excludedColorIds: [Int]
                let tie: Bool?
                let tiedColorIds: [Int]?
            }

            let id: String
            let category: String
            let description: String?
            let scope: String?
            let weights: [String: Double]
            let target: [String: Double]
            let palette: [PaletteEntry]
            let expected: Expected
        }

        let schemaVersion: Int
        let tolerance: Double?
        let cases: [Case]
    }

    private static let supportedSchemaVersion = 1
    private static let requiredCategories: Set<String> = [
        "exact_match",
        "weighting",
        "tie",
        "exclusion_candidate_missing",
        "exclusion_all",
        "exclusion_target_missing",
        "zero_weight_optional",
        "multi_channel",
    ]

    /// The corpus is committed next to the test target so a plain checkout
    /// (CI or `swift test`) can read it without resource-bundling.
    private static let corpusURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/solver_parity_corpus.json")

    private var loadedCorpus: Corpus?

    private func loadCorpus() throws -> Corpus {
        if let loadedCorpus { return loadedCorpus }
        do {
            let data = try Data(contentsOf: Self.corpusURL)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let corpus = try decoder.decode(Corpus.self, from: data)
            loadedCorpus = corpus
            return corpus
        } catch let error as CorpusError {
            throw error
        } catch {
            throw CorpusError.unreadable(Self.corpusURL, underlying: String(describing: error))
        }
    }

    private func makeWeights(_ raw: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: raw["white"] ?? 0,
            red: raw["red"] ?? 0,
            green: raw["green"] ?? 0,
            blue: raw["blue"] ?? 0,
            lps: raw["lps"] ?? 0
        )
    }

    private func makePalette(_ entries: [Corpus.Case.PaletteEntry]) throws -> [PaletteColor] {
        try entries.map { entry in
            guard let rgb = RGBColor(hex: entry.hex) else {
                throw CorpusError.authoring("color \(entry.id): unparseable hex \"\(entry.hex)\"")
            }
            var responses: [LightingCondition: IlluminationResponse] = [:]
            for (key, value) in entry.responses {
                guard let condition = LightingCondition(rawValue: key) else {
                    throw CorpusError.unknownCondition(key, caseID: "palette color \(entry.id)")
                }
                responses[condition] = IlluminationResponse(brightness: value)
            }
            return PaletteColor(
                id: entry.id,
                name: entry.name,
                hex: entry.hex,
                rgb: rgb,
                responses: responses
            )
        }
    }

    private func makeTarget(_ raw: [String: Double]) throws -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in raw {
            guard let condition = LightingCondition(rawValue: key) else {
                throw CorpusError.unknownCondition(key, caseID: "target")
            }
            brightness[condition] = value
        }
        return TargetResponseVector(brightness)
    }

    /// Solves a single-cell composition whose per-condition source values are
    /// the case's target vector, so the solver's full selection path — scorer,
    /// fast path, tie-breaking — is exercised exactly as in production.
    private func solveSelection(_ testCase: Corpus.Case) throws -> (result: CompositionResult, palette: [PaletteColor]) {
        let weights = makeWeights(testCase.weights)
        let palette = try makePalette(testCase.palette)
        let target = try makeTarget(testCase.target)

        var sourceGrids: [LightingCondition: BrightnessGrid] = [:]
        for condition in weights.activeConditions {
            guard let value = target.value(for: condition) else {
                throw CorpusError.authoring(
                    "case \(testCase.id): selection scope requires a target value for active condition \(condition.rawValue)"
                )
            }
            sourceGrids[condition] = BrightnessGrid(width: 1, height: 1, values: [value])
        }

        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: sourceGrids,
            weights: weights
        )
        return (result, palette)
    }

    private func scorer() -> WeightedSquaredErrorScorer {
        WeightedSquaredErrorScorer()
    }

    // MARK: - Corpus integrity

    func testCorpusSchemaIsSupported() throws {
        let corpus = try loadCorpus()
        guard corpus.schemaVersion == Self.supportedSchemaVersion else {
            throw CorpusError.unsupportedSchema(corpus.schemaVersion)
        }
        XCTAssertFalse(corpus.cases.isEmpty, "Parity corpus must contain at least one case")
    }

    func testCorpusCoversRequiredCategories() throws {
        let corpus = try loadCorpus()
        let present = Set(corpus.cases.map(\.category))
        let missing = Self.requiredCategories.subtracting(present).sorted()
        XCTAssertTrue(
            missing.isEmpty,
            "Parity corpus is missing cases for required categories: \(missing.joined(separator: ", "))"
        )
        XCTAssertGreaterThanOrEqual(corpus.cases.count, Self.requiredCategories.count)
    }

    func testCorpusCaseIDsAreUnique() throws {
        let corpus = try loadCorpus()
        let ids = corpus.cases.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Parity corpus case ids must be unique")
    }

    // MARK: - Parity

    func testSelectionsMatchCorpusExactly() throws {
        let corpus = try loadCorpus()
        let tolerance = corpus.tolerance ?? 1e-9

        for testCase in corpus.cases {
            let scope = testCase.scope ?? "selection"
            switch scope {
            case "selection":
                try assertSelectionParity(testCase, tolerance: tolerance)
            case "scorer_only":
                continue
            default:
                throw CorpusError.unknownScope(scope, caseID: testCase.id)
            }
        }
    }

    func testScorerLevelParityMatchesCorpus() throws {
        let corpus = try loadCorpus()
        let tolerance = corpus.tolerance ?? 1e-9

        for testCase in corpus.cases {
            let scope = testCase.scope ?? "selection"
            switch scope {
            case "scorer_only":
                try assertScorerOnlyParity(testCase, tolerance: tolerance)
            case "selection":
                continue
            default:
                throw CorpusError.unknownScope(scope, caseID: testCase.id)
            }
        }
    }

    /// Selection-scope parity: the solver must pick exactly the expected color,
    /// at exactly the expected score, with the documented exclusions and
    /// earliest-palette-order tie-breaking.
    private func assertSelectionParity(_ testCase: Corpus.Case, tolerance: Double) throws {
        let (result, palette) = try solveSelection(testCase)
        let expected = testCase.expected
        let caseRef = "case \(testCase.id)"

        try validateCaseReferences(testCase, palette: palette)

        // `colorIndices` is `[Int?]`; flatten `.first` down to a plain `Int?`.
        let selectedIndex = result.colorIndices.first.flatMap { $0 }

        if let expectedID = expected.selectedColorId {
            guard let expectedScore = expected.score else {
                throw CorpusError.authoring("case \(testCase.id): a selection must carry an expected score")
            }
            let index = try indexOfColor(expectedID, in: palette, caseRef: caseRef)
            XCTAssertEqual(
                selectedIndex,
                index,
                "\(caseRef): expected color \(expectedID) to be selected"
            )
            guard let selectedIndex else { return }

            XCTAssertEqual(
                result.errors.first ?? .infinity,
                expectedScore,
                accuracy: tolerance,
                "\(caseRef): solver error for selected color must match expected score"
            )

            let directScore = scorer().score(
                candidate: palette[index],
                target: try makeTarget(testCase.target),
                weights: makeWeights(testCase.weights)
            )
            guard case .score(let value) = directScore else {
                return XCTFail("\(caseRef): selected color must not be excluded by the scorer")
            }
            XCTAssertEqual(
                value,
                expectedScore,
                accuracy: tolerance,
                "\(caseRef): scorer score for selected color must match expected score"
            )
        } else {
            XCTAssertNil(
                selectedIndex,
                "\(caseRef): expected no selectable color, but index \(String(describing: selectedIndex)) was selected"
            )
            XCTAssertEqual(result.unmatchedCellCount, 1, "\(caseRef): the single cell must be unmatched")
            XCTAssertTrue(
                (result.errors.first ?? 0).isInfinite,
                "\(caseRef): unmatched cell error must be infinite"
            )
        }

        XCTAssertEqual(
            result.excludedCandidateCount,
            expected.excludedColorIds.count,
            "\(caseRef): excluded candidate count must match the expected exclusions"
        )

        try assertExclusions(testCase, palette: palette)
        try assertTiePolicy(testCase, palette: palette, tolerance: tolerance)
    }

    /// Scorer-only parity for cases the solver cannot express (a target that
    /// itself lacks a required condition).
    private func assertScorerOnlyParity(_ testCase: Corpus.Case, tolerance: Double) throws {
        let palette = try makePalette(testCase.palette)
        let expected = testCase.expected
        let caseRef = "case \(testCase.id)"
        let target = try makeTarget(testCase.target)
        let weights = makeWeights(testCase.weights)

        try validateCaseReferences(testCase, palette: palette)
        XCTAssertNil(
            expected.selectedColorId,
            "\(caseRef): scorer_only cases must not expect a selection"
        )

        for color in palette {
            let outcome = scorer().score(candidate: color, target: target, weights: weights)
            let isExcluded: Bool
            if case .excluded = outcome { isExcluded = true } else { isExcluded = false }
            let expectedExcluded = expected.excludedColorIds.contains(color.id)
            XCTAssertEqual(
                isExcluded,
                expectedExcluded,
                "\(caseRef): color \(color.id) exclusion must match the corpus"
            )
            if !expectedExcluded, case .score(let value) = outcome, let expectedScore = expected.score {
                XCTAssertEqual(
                    value,
                    expectedScore,
                    accuracy: tolerance,
                    "\(caseRef): color \(color.id) score must match expected score"
                )
            }
        }
    }

    private func assertExclusions(_ testCase: Corpus.Case, palette: [PaletteColor]) throws {
        let caseRef = "case \(testCase.id)"
        let target = try makeTarget(testCase.target)
        let weights = makeWeights(testCase.weights)

        for color in palette {
            let outcome = scorer().score(candidate: color, target: target, weights: weights)
            let expectedExcluded = testCase.expected.excludedColorIds.contains(color.id)
            let isExcluded: Bool
            if case .excluded = outcome { isExcluded = true } else { isExcluded = false }
            XCTAssertEqual(
                isExcluded,
                expectedExcluded,
                "\(caseRef): color \(color.id) exclusion must match the corpus"
            )
        }
    }

    /// On ties the winner must be the tied color appearing earliest in palette
    /// order — the `IlluminantMatching.best_match/4` policy — and every tied
    /// color must share the winning score.
    private func assertTiePolicy(_ testCase: Corpus.Case, palette: [PaletteColor], tolerance: Double) throws {
        let caseRef = "case \(testCase.id)"
        guard testCase.expected.tie == true else { return }
        guard let tiedIDs = testCase.expected.tiedColorIds, !tiedIDs.isEmpty else {
            throw CorpusError.authoring("\(caseRef): tie cases must list tied_color_ids")
        }

        let target = try makeTarget(testCase.target)
        let weights = makeWeights(testCase.weights)
        let winningScore = testCase.expected.score

        var firstTiedIndex: Int?
        for (index, color) in palette.enumerated() where tiedIDs.contains(color.id) {
            if firstTiedIndex == nil { firstTiedIndex = index }
            guard case .score(let value) = scorer().score(candidate: color, target: target, weights: weights) else {
                return XCTFail("\(caseRef): tied color \(color.id) must not be excluded")
            }
            if let winningScore {
                XCTAssertEqual(
                    value,
                    winningScore,
                    accuracy: tolerance,
                    "\(caseRef): every tied color must share the winning score"
                )
            }
        }

        guard let expectedID = testCase.expected.selectedColorId, let tied = firstTiedIndex else {
            throw CorpusError.authoring("\(caseRef): tie cases must expect a selection")
        }
        let expectedIndex = try indexOfColor(expectedID, in: palette, caseRef: caseRef)
        XCTAssertEqual(
            expectedIndex,
            tied,
            "\(caseRef): tie must resolve to the earliest palette entry among \(tiedIDs)"
        )
    }

    // MARK: - Reference validation

    private func validateCaseReferences(_ testCase: Corpus.Case, palette: [PaletteColor]) throws {
        let ids = palette.map(\.id)
        let caseRef = "case \(testCase.id)"
        guard ids.count == Set(ids).count else {
            throw CorpusError.authoring("\(caseRef): palette color ids must be unique")
        }
        for id in testCase.expected.excludedColorIds where !ids.contains(id) {
            throw CorpusError.authoring("\(caseRef): excluded color \(id) is not in the palette")
        }
        for id in testCase.expected.tiedColorIds ?? [] where !ids.contains(id) {
            throw CorpusError.authoring("\(caseRef): tied color \(id) is not in the palette")
        }
    }

    private func indexOfColor(_ id: Int, in palette: [PaletteColor], caseRef: String) throws -> Int {
        guard let index = palette.firstIndex(where: { $0.id == id }) else {
            throw CorpusError.authoring("\(caseRef): expected color \(id) is not in the palette")
        }
        return index
    }
}
