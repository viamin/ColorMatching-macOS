import XCTest
@testable import ColorComposerCore

/// Solver parity against the committed corpus (issue #39).
///
/// Loads `Fixtures/solver_parity_corpus.json` — the corpus published by
/// viamin/color_matching#111 (seeded from the documented
/// `WeightedSquaredError` semantics until that lands) — and asserts that the
/// production selection path (`CompositionSolver` with the default
/// `WeightedSquaredErrorScorer`) reproduces every expected selection exactly,
/// including tie cases (earliest candidate wins) and exclusion cases
/// (candidates missing a required measurement are never selected).
///
/// Selection runs through the real solver with a 1×1 grid per corpus target so
/// the corpus exercises the same fast-path selection the app uses, not a
/// re-implementation of the scorer inside the test.
final class SolverParityCorpusTests: XCTestCase {
    private struct ParityCorpus: Decodable {
        let version: Int
        let cases: [ParityCase]
    }

    private struct ParityCase: Decodable {
        let id: String
        let description: String?
        let tags: [String]?
        let weights: [String: Double]
        let target: [String: Double]
        let candidates: [ParityCandidate]
        let expectedSelection: String?
        let expectedScore: Double?
        let expectedExcluded: [String]?

        private enum CodingKeys: String, CodingKey {
            case id, description, tags, weights, target, candidates
            case expectedSelection = "expected_selection"
            case expectedScore = "expected_score"
            case expectedExcluded = "expected_excluded"
        }
    }

    private struct ParityCandidate: Decodable {
        let name: String
        let responses: [String: Double]
    }

    private enum CorpusError: Error, CustomStringConvertible {
        case fixtureMissing(URL)
        case unknownLightSource(String, caseID: String)
        case targetMissingActiveChannel(condition: LightingCondition, caseID: String)
        case duplicateCandidateName(String, caseID: String)

        var description: String {
            switch self {
            case .fixtureMissing(let url):
                return "Parity corpus fixture not found at \(url.path). See docs/solver-parity-corpus.md."
            case .unknownLightSource(let key, let caseID):
                return "Case '\(caseID)': light source '\(key)' is not a canonical LightingCondition."
            case .targetMissingActiveChannel(let condition, let caseID):
                return "Case '\(caseID)': target has no value for active channel \(condition.rawValue)."
            case .duplicateCandidateName(let name, let caseID):
                return "Case '\(caseID)': duplicate candidate name '\(name)'."
            }
        }
    }

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/solver_parity_corpus.json")

    private static let requiredTags = ["doctest", "tie", "exclusion", "weights"]

    // MARK: - Corpus loading

    func testCorpusLoadsAndCoversRequiredBehaviors() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.version, 1, "Corpus format version must stay in sync with this loader.")
        XCTAssertGreaterThanOrEqual(corpus.cases.count, 9, "Corpus must keep at least the seed coverage.")

        let tags = Set(corpus.cases.flatMap { $0.tags ?? [] })
        for tag in Self.requiredTags where !tags.contains(tag) {
            XCTFail("Corpus must keep at least one case tagged '\(tag)' (doctest parity, ties, exclusions, or weight handling would otherwise be untested).")
        }
    }

    func testSelectionsMatchCorpusExactly() throws {
        let corpus = try loadCorpus()
        XCTAssertFalse(corpus.cases.isEmpty, "Empty parity corpus cannot enforce solver parity.")

        for parityCase in corpus.cases {
            try runAndVerify(parityCase)
        }
    }

    // MARK: - Case execution

    private func runAndVerify(_ parityCase: ParityCase) throws {
        let context = try makeSelectionContext(for: parityCase)
        let result = try CompositionSolver().solve(
            palette: context.palette,
            sourceGrids: context.sourceGrids,
            weights: context.weights
        )
        let selectedIndex = result.colorIndex(x: 0, y: 0)

        if let expected = parityCase.expectedSelection {
            let index = try XCTUnwrap(
                selectedIndex,
                "Case '\(parityCase.id)': expected selection '\(expected)' but the cell went unmatched."
            )
            XCTAssertEqual(
                context.palette[index].name, expected,
                "Case '\(parityCase.id)': selection mismatch."
            )
        } else {
            XCTAssertNil(
                selectedIndex,
                "Case '\(parityCase.id)': expected no eligible selection but index \(String(describing: selectedIndex)) was chosen."
            )
            XCTAssertTrue(
                result.error(x: 0, y: 0).isInfinite,
                "Case '\(parityCase.id)': an unmatched cell must record infinite error."
            )
        }

        if let expectedScore = parityCase.expectedScore {
            let error = result.error(x: 0, y: 0)
            guard error.isFinite else {
                return XCTFail("Case '\(parityCase.id)': expected score \(expectedScore) but error was \(error).")
            }
            XCTAssertEqual(error, expectedScore, accuracy: 1e-9, "Case '\(parityCase.id)': score mismatch.")
        }

        try verifyExclusions(parityCase, context: context)
    }

    private func verifyExclusions(_ parityCase: ParityCase, context: SelectionContext) throws {
        let expectedExcluded = Set(parityCase.expectedExcluded ?? [])
        let scorer = WeightedSquaredErrorScorer()
        let target = TargetResponseVector(context.target)

        for candidate in context.palette {
            let isExcluded = scorer.score(candidate: candidate, target: target, weights: context.weights) == .excluded
            let name = candidate.name ?? ""
            if expectedExcluded.contains(name) {
                XCTAssertTrue(
                    isExcluded,
                    "Case '\(parityCase.id)': candidate '\(name)' must be excluded (missing a required measurement)."
                )
            } else {
                XCTAssertFalse(
                    isExcluded,
                    "Case '\(parityCase.id)': candidate '\(name)' must not be excluded."
                )
            }
        }

        XCTAssertEqual(
            context.palette.filter { expectedExcluded.contains($0.name ?? "") }.count,
            expectedExcluded.count,
            "Case '\(parityCase.id)': expected_excluded names candidate names that do not exist."
        )
    }

    // MARK: - Corpus → solver inputs

    private struct SelectionContext {
        let palette: [PaletteColor]
        let sourceGrids: [LightingCondition: BrightnessGrid]
        let weights: ChannelWeights
        let target: [LightingCondition: Double]
    }

    private func makeSelectionContext(for parityCase: ParityCase) throws -> SelectionContext {
        let weightsByCondition = try conditions(from: parityCase.weights, caseID: parityCase.id)
        let targetByCondition = try conditions(from: parityCase.target, caseID: parityCase.id)

        let weights = ChannelWeights(
            white: weightsByCondition[.white] ?? 0,
            red: weightsByCondition[.red] ?? 0,
            green: weightsByCondition[.green] ?? 0,
            blue: weightsByCondition[.blue] ?? 0,
            lps: weightsByCondition[.lps] ?? 0
        )

        var sourceGrids: [LightingCondition: BrightnessGrid] = [:]
        for (condition, weight) in weightsByCondition where weight > 0 {
            guard let value = targetByCondition[condition] else {
                throw CorpusError.targetMissingActiveChannel(condition: condition, caseID: parityCase.id)
            }
            sourceGrids[condition] = BrightnessGrid(width: 1, height: 1, values: [value])
        }

        let names = parityCase.candidates.map(\.name)
        if Set(names).count != names.count {
            throw CorpusError.duplicateCandidateName(
                names.first { name in names.filter { $0 == name }.count > 1 } ?? "?",
                caseID: parityCase.id
            )
        }

        let palette = try parityCase.candidates.enumerated().map { index, candidate in
            PaletteColor(
                id: index,
                name: candidate.name,
                hex: "#000000",
                rgb: RGBColor(hex: "#000000")!,
                responses: try conditions(from: candidate.responses, caseID: parityCase.id)
                    .mapValues { IlluminationResponse(brightness: $0) }
            )
        }

        return SelectionContext(
            palette: palette,
            sourceGrids: sourceGrids,
            weights: weights,
            target: targetByCondition
        )
    }

    /// Maps corpus light-source keys onto `LightingCondition`, failing loudly
    /// when the corpus and the enum have drifted apart.
    private func conditions(
        from values: [String: Double],
        caseID: String
    ) throws -> [LightingCondition: Double] {
        var mapped: [LightingCondition: Double] = [:]
        for (key, value) in values {
            guard let condition = LightingCondition(rawValue: key) else {
                throw CorpusError.unknownLightSource(key, caseID: caseID)
            }
            mapped[condition] = value
        }
        return mapped
    }

    private func loadCorpus() throws -> ParityCorpus {
        let url = Self.fixtureURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CorpusError.fixtureMissing(url)
        }
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }
}
