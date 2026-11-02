import Foundation
import XCTest
@testable import ColorComposerCore

/// Consumes the solver parity corpus published by `viamin/color_matching#111`
/// and asserts `WeightedSquaredErrorScorer` selections match its expected
/// outputs exactly — including tie and exclusion cases (issue #39).
///
/// The corpus is a committed test fixture at
/// `Tests/ColorComposerCoreTests/Fixtures/parity_corpus.json`; see
/// `docs/solver-parity-corpus.md` for the schema and refresh flow.
final class SolverParityCorpusTests: XCTestCase {
    private static let committedCorpusFilename = "parity_corpus.json"
    private static let seedCorpusFilename = "parity_corpus.seed.json"
    private static let scoreTolerance = 1e-9
    private static let tieTolerance = 1e-12

    // MARK: - Committed corpus (viamin/color_matching#111)

    func testCommittedParityCorpusExistsAndDecodes() {
        XCTAssertNotNil(
            committedCorpus(),
            "The committed solver parity corpus could not be loaded from \(Self.corpusURL(Self.committedCorpusFilename).path)."
        )
    }

    func testSelectionsMatchCommittedParityCorpus() throws {
        guard let corpus = committedCorpus() else { return }

        let failures = corpusStructureFailures(for: corpus) + parityFailures(for: corpus)

        XCTAssertTrue(
            failures.isEmpty,
            "WeightedSquaredErrorScorer diverged from \(corpus.cases.count) corpus cases (\(failures.count) failures):\n"
                + failures.joined(separator: "\n")
        )
    }

    func testCommittedCorpusCoversTiesAndExclusions() throws {
        guard let corpus = committedCorpus() else { return }

        let evaluated = corpus.cases.compactMap { try? evaluate($0) }
        let failures = coverageFailures(for: evaluated)

        XCTAssertTrue(
            failures.isEmpty,
            "The committed parity corpus lacks required coverage:\n" + failures.joined(separator: "\n")
        )
    }

    // MARK: - Harness validation (seed corpus)

    /// The seed corpus is hand-derived (it includes the Elixir
    /// `WeightedSquaredError` doctest case) and exists only to prove the
    /// loader, selection policy replication, and tie/exclusion handling are
    /// correct before the upstream corpus lands. It is not a parity source.
    func testSeedCorpusValidatesTheParityHarness() throws {
        let corpus = try Self.loadCorpus(at: Self.corpusURL(Self.seedCorpusFilename))
        let evaluated = corpus.cases.compactMap { try? evaluate($0) }

        let failures = corpusStructureFailures(for: corpus)
            + parityFailures(for: corpus)
            + coverageFailures(for: evaluated)

        XCTAssertTrue(
            failures.isEmpty,
            "The parity harness failed its seed validation (\(failures.count) failures):\n"
                + failures.joined(separator: "\n")
        )
    }

    // MARK: - Corpus loading

    private static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    private static func corpusURL(_ filename: String) -> URL {
        fixturesDirectory.appendingPathComponent(filename)
    }

    private static func loadCorpus(at url: URL) throws -> ParityCorpus {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: url))
    }

    private func committedCorpus() -> ParityCorpus? {
        let url = Self.corpusURL(Self.committedCorpusFilename)
        do {
            return try Self.loadCorpus(at: url)
        } catch {
            XCTFail(
                "The committed solver parity corpus could not be loaded from \(url.path) (\(error)). "
                    + "Commit the corpus published by viamin/color_matching#111 there — see docs/solver-parity-corpus.md."
            )
            return nil
        }
    }

    // MARK: - Case evaluation

    private struct EvaluatedCase {
        let name: String
        let selectedID: Int?
        let winningScore: Double?
        let excludedIDs: Set<Int>
        let tiedWinnerIDs: [Int]
    }

    private func evaluate(_ parityCase: ParityCase) throws -> EvaluatedCase {
        let weights = try Self.channelWeights(from: parityCase.weights, in: parityCase.name)
        let target = try Self.targetVector(from: parityCase.target, in: parityCase.name)
        let scorer = WeightedSquaredErrorScorer()

        var selectedID: Int?
        var winningScore: Double?
        var excludedIDs = Set<Int>()
        var rankable: [(id: Int, score: Double)] = []

        for candidate in parityCase.candidates {
            let domain = try Self.domainColor(from: candidate, in: parityCase.name)
            switch scorer.score(candidate: domain, target: target, weights: weights) {
            case .excluded:
                excludedIDs.insert(candidate.id)
            case .score(let score):
                rankable.append((candidate.id, score))
                // Strictly-lower wins, so the earliest candidate wins ties —
                // mirroring CompositionSolver.bestCandidate exactly.
                if score < (winningScore ?? .infinity) {
                    winningScore = score
                    selectedID = candidate.id
                }
            }
        }

        let tiedWinnerIDs = winningScore.map { winner in
            rankable.filter { abs($0.score - winner) <= Self.tieTolerance }.map(\.id)
        } ?? []

        return EvaluatedCase(
            name: parityCase.name,
            selectedID: selectedID,
            winningScore: winningScore,
            excludedIDs: excludedIDs,
            tiedWinnerIDs: tiedWinnerIDs
        )
    }

    private static func condition(forKey key: String, in caseName: String) throws -> LightingCondition {
        guard let condition = LightingCondition(rawValue: key) else {
            throw ParityCorpusError("case '\(caseName)': unknown light source '\(key)'")
        }
        return condition
    }

    private static func channelWeights(
        from raw: [String: Double],
        in caseName: String
    ) throws -> ChannelWeights {
        var byCondition = [LightingCondition: Double]()
        for (key, value) in raw {
            let condition = try condition(forKey: key, in: caseName)
            guard value >= 0 else {
                throw ParityCorpusError("case '\(caseName)': weight for '\(key)' is negative")
            }
            byCondition[condition] = value
        }
        return ChannelWeights(
            white: byCondition[.white] ?? 0,
            red: byCondition[.red] ?? 0,
            green: byCondition[.green] ?? 0,
            blue: byCondition[.blue] ?? 0,
            lps: byCondition[.lps] ?? 0
        )
    }

    private static func targetVector(
        from raw: [String: Double],
        in caseName: String
    ) throws -> TargetResponseVector {
        var brightness = [LightingCondition: Double]()
        for (key, value) in raw {
            brightness[try condition(forKey: key, in: caseName)] = value
        }
        return TargetResponseVector(brightness)
    }

    private static func domainColor(
        from candidate: ParityCandidate,
        in caseName: String
    ) throws -> PaletteColor {
        let hex = candidate.hex ?? "#000000"
        guard let rgb = RGBColor(hex: hex) else {
            throw ParityCorpusError("case '\(caseName)': candidate \(candidate.id) has unparseable hex '\(hex)'")
        }
        var responses = [LightingCondition: IlluminationResponse]()
        for (key, brightness) in candidate.responses {
            responses[try condition(forKey: key, in: caseName)] = IlluminationResponse(brightness: brightness)
        }
        return PaletteColor(id: candidate.id, hex: hex, rgb: rgb, responses: responses)
    }

    // MARK: - Failure collection

    private func parityFailures(for corpus: ParityCorpus) -> [String] {
        var failures: [String] = []
        for parityCase in corpus.cases {
            let evaluated: EvaluatedCase
            do {
                evaluated = try evaluate(parityCase)
            } catch {
                failures.append(String(describing: error))
                continue
            }

            if evaluated.selectedID != parityCase.expectedSelection {
                failures.append(
                    "case '\(parityCase.name)': expected selection \(describe(parityCase.expectedSelection)) "
                        + "but selected \(describe(evaluated.selectedID))"
                )
            }
            let expectedExcluded = Set(parityCase.expectedExcludedIds ?? [])
            if evaluated.excludedIDs != expectedExcluded {
                failures.append(
                    "case '\(parityCase.name)': expected excluded \(sortedDescription(expectedExcluded)) "
                        + "but excluded \(sortedDescription(evaluated.excludedIDs))"
                )
            }
            if let expectedScore = parityCase.expectedScore {
                if let actual = evaluated.winningScore {
                    if abs(actual - expectedScore) > Self.scoreTolerance {
                        failures.append(
                            "case '\(parityCase.name)': expected winning score \(expectedScore) but scored \(actual)"
                        )
                    }
                } else {
                    failures.append(
                        "case '\(parityCase.name)': expected winning score \(expectedScore) but every candidate was excluded"
                    )
                }
            }
        }
        return failures
    }

    private func corpusStructureFailures(for corpus: ParityCorpus) -> [String] {
        var failures: [String] = []
        if corpus.version != 1 {
            failures.append("unsupported corpus version \(corpus.version); expected 1")
        }
        if corpus.cases.isEmpty {
            failures.append("corpus contains no cases")
        }
        for parityCase in corpus.cases {
            let ids = parityCase.candidates.map(\.id)
            if Set(ids).count != ids.count {
                failures.append("case '\(parityCase.name)': duplicate candidate ids \(ids)")
            }
            if parityCase.candidates.isEmpty {
                failures.append("case '\(parityCase.name)': no candidates")
            }
            if let expected = parityCase.expectedSelection, !ids.contains(expected) {
                failures.append("case '\(parityCase.name)': expected selection \(expected) is not a candidate id")
            }
            for id in parityCase.expectedExcludedIds ?? [] where !ids.contains(id) {
                failures.append("case '\(parityCase.name)': expected excluded id \(id) is not a candidate id")
            }
        }
        return failures
    }

    private func coverageFailures(for evaluated: [EvaluatedCase]) -> [String] {
        var failures: [String] = []
        if !evaluated.contains(where: { $0.tiedWinnerIDs.count >= 2 }) {
            failures.append(
                "no tie case: at least one case needs two rankable candidates sharing the winning score, "
                    + "so earliest-wins tie-breaking is exercised"
            )
        }
        if !evaluated.contains(where: { !$0.excludedIDs.isEmpty }) {
            failures.append(
                "no exclusion case: at least one case needs a candidate excluded for missing a required-channel measurement"
            )
        }
        return failures
    }

    private func describe(_ id: Int?) -> String {
        id.map(String.init) ?? "no candidate (all excluded)"
    }

    private func sortedDescription(_ ids: Set<Int>) -> String {
        "[\(ids.sorted().map(String.init).joined(separator: ", "))]"
    }
}

// MARK: - Corpus wire format

private struct ParityCorpusError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}

private struct ParityCorpus: Decodable {
    let version: Int
    let source: String?
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: [String: Double]
    let target: [String: Double]
    let candidates: [ParityCandidate]
    let expectedSelection: Int?
    let expectedScore: Double?
    let expectedExcludedIds: [Int]?
}

private struct ParityCandidate: Decodable {
    let id: Int
    let hex: String?
    let responses: [String: Double]
}
