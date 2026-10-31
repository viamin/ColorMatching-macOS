import XCTest
@testable import ColorComposerCore

/// Solver parity against the `WeightedSquaredError` corpus published by
/// `color_matching` (viamin/color_matching#111).
///
/// Every case drives `WeightedSquaredErrorScorer` over the corpus palette and
/// asserts the selected candidate, score, tie flag, and exclusion count match
/// the expected output exactly — then replays the same case through
/// `CompositionSolver` on a 1×1 grid so the full selection pipeline (fast path,
/// earliest-wins tie-breaking, exclusion policy) agrees too.
///
/// Corpus lookup order (see `docs/solver-parity-corpus.md`):
/// 1. `PARITY_CORPUS_PATH` environment override,
/// 2. `color_matching/priv/solver_parity_corpus.json` — the upstream copy
///    when the server repository is checked out next to this repo,
/// 3. the corpus committed in `Fixtures/` beside this test.
final class SolverParityCorpusTests: XCTestCase {
    // MARK: - Corpus wire format

    private struct Corpus: Codable {
        struct Case: Codable {
            struct PaletteEntry: Codable {
                let id: Int
                var name: String?
                let hex: String
                let responses: [String: Double]
            }

            struct Expected: Codable {
                let selectionIndex: Int?
                let score: Double?
                let tie: Bool?
                let excludedCandidates: Int?
            }

            let id: String
            var description: String?
            let palette: [PaletteEntry]
            let weights: [String: Double]
            let target: [String: Double]
            let expected: Expected
        }

        let version: Int
        var source: String?
        let cases: [Case]
    }

    private struct CorpusFormatError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private struct SelectionOutcome {
        let index: Int?
        let score: Double?
        let isTie: Bool
        let excludedCount: Int
    }

    // MARK: - Corpus location

    /// Repository root, derived from this file's checked-out location.
    static var defaultRepositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // …/ColorComposerCoreTests
            .deletingLastPathComponent()    // …/Tests
            .deletingLastPathComponent()    // …/ColorComposerCore
            .deletingLastPathComponent()    // repository root
    }

    /// The corpus vendored into this repository, refreshed from upstream.
    static var bundledFixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity_corpus.json")
    }

    /// Candidate corpus locations in lookup order.
    static func corpusLocations(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        repositoryRoot: URL = SolverParityCorpusTests.defaultRepositoryRoot
    ) -> [URL] {
        var candidates: [URL] = []
        if let override = environment["PARITY_CORPUS_PATH"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates.append(
            repositoryRoot.appendingPathComponent("color_matching/priv/solver_parity_corpus.json")
        )
        candidates.append(bundledFixtureURL)
        return candidates
    }

    /// Loads the parity corpus from the first location that exists on disk.
    private static func loadCorpus() throws -> (url: URL, corpus: Corpus) {
        let candidates = corpusLocations()
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            do {
                return (url, try decodeCorpus(at: url))
            } catch {
                throw CorpusFormatError(message: "parity corpus at \(url.path) failed to decode: \(error)")
            }
        }
        let searched = candidates.map(\.path).joined(separator: ", ")
        throw CorpusFormatError(message: "no parity corpus found; searched: \(searched)")
    }

    private static func decodeCorpus(at url: URL) throws -> Corpus {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Corpus.self, from: Data(contentsOf: url))
    }

    // MARK: - Corpus → domain conversion

    private static func makeWeights(_ map: [String: Double]) throws -> ChannelWeights {
        var weights = ChannelWeights()
        for (key, value) in map {
            switch key {
            case LightingCondition.white.rawValue: weights.white = value
            case LightingCondition.red.rawValue: weights.red = value
            case LightingCondition.green.rawValue: weights.green = value
            case LightingCondition.blue.rawValue: weights.blue = value
            case LightingCondition.lps.rawValue: weights.lps = value
            default:
                throw CorpusFormatError(message: "unknown lighting condition in weights: \(key)")
            }
        }
        return weights
    }

    private static func makeTarget(_ map: [String: Double]) throws -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in map {
            guard let condition = LightingCondition(rawValue: key) else {
                throw CorpusFormatError(message: "unknown lighting condition in target: \(key)")
            }
            brightness[condition] = value
        }
        return TargetResponseVector(brightness)
    }

    private static func makePaletteColor(_ entry: Corpus.Case.PaletteEntry) throws -> PaletteColor {
        guard let rgb = RGBColor(hex: entry.hex) else {
            throw CorpusFormatError(message: "unparseable hex for palette entry \(entry.id): \(entry.hex)")
        }
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, brightness) in entry.responses {
            guard let condition = LightingCondition(rawValue: key) else {
                throw CorpusFormatError(message: "unknown lighting condition in responses of entry \(entry.id): \(key)")
            }
            responses[condition] = IlluminationResponse(brightness: brightness)
        }
        return PaletteColor(id: entry.id, name: entry.name, hex: entry.hex, rgb: rgb, responses: responses)
    }

    private static func makeSourceGrids(
        weights: ChannelWeights,
        target: [String: Double]
    ) throws -> [LightingCondition: BrightnessGrid] {
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for condition in weights.activeConditions {
            guard let value = target[condition.rawValue] else {
                throw CorpusFormatError(message: "target is missing active channel \(condition.rawValue)")
            }
            grids[condition] = BrightnessGrid(width: 1, height: 1, values: [value])
        }
        return grids
    }

    // MARK: - Selection under test

    /// Selects the best candidate with the solver's policy: lowest score wins,
    /// ties go to the earliest palette entry, excluded candidates never rank.
    private static func selectBestCandidate(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> SelectionOutcome {
        let scorer = WeightedSquaredErrorScorer()
        var bestIndex: Int?
        var bestScore = Double.infinity
        var bestCount = 0
        var excludedCount = 0

        for (index, candidate) in palette.enumerated() {
            switch scorer.score(candidate: candidate, target: target, weights: weights) {
            case .excluded:
                excludedCount += 1
            case .score(let value):
                if value < bestScore {
                    bestScore = value
                    bestIndex = index
                    bestCount = 1
                } else if value == bestScore {
                    bestCount += 1
                }
            }
        }

        return SelectionOutcome(
            index: bestIndex,
            score: bestIndex == nil ? nil : bestScore,
            isTie: bestCount > 1,
            excludedCount: excludedCount
        )
    }

    // MARK: - Parity tests

    func testCorpusSelectionsMatchExpectedOutputs() throws {
        let (_, corpus) = try Self.loadCorpus()
        XCTAssertGreaterThanOrEqual(corpus.cases.count, 10, "parity corpus should keep its case coverage")

        for testCase in corpus.cases {
            let palette = try testCase.palette.map(Self.makePaletteColor)
            let weights = try Self.makeWeights(testCase.weights)
            let target = try Self.makeTarget(testCase.target)

            let outcome = Self.selectBestCandidate(palette: palette, target: target, weights: weights)

            XCTAssertEqual(
                outcome.index, testCase.expected.selectionIndex,
                "case \(testCase.id): selected palette index"
            )
            XCTAssertEqual(
                outcome.isTie, testCase.expected.tie ?? false,
                "case \(testCase.id): tie flag"
            )
            XCTAssertEqual(
                outcome.excludedCount, testCase.expected.excludedCandidates ?? 0,
                "case \(testCase.id): excluded candidate count"
            )
            assertScore(outcome.score, matches: testCase.expected.score, caseID: testCase.id)

            try assertSolverAgrees(
                palette: palette, weights: weights, target: testCase.target, testCase: testCase
            )
        }
    }

    private func assertScore(
        _ actual: Double?, matches expected: Double?, caseID: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        switch (actual, expected) {
        case let (actual?, expected?):
            XCTAssertEqual(actual, expected, accuracy: 1e-9, "case \(caseID): score", file: file, line: line)
        case (nil, nil):
            break
        default:
            XCTFail("case \(caseID): score presence mismatch (got \(String(describing: actual)), expected \(String(describing: expected)))", file: file, line: line)
        }
    }

    private func assertSolverAgrees(
        palette: [PaletteColor],
        weights: ChannelWeights,
        target: [String: Double],
        testCase: Corpus.Case,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let grids = try Self.makeSourceGrids(weights: weights, target: target)
        let result = try CompositionSolver(scorer: WeightedSquaredErrorScorer())
            .solve(palette: palette, sourceGrids: grids, weights: weights)

        XCTAssertEqual(
            result.colorIndex(x: 0, y: 0), testCase.expected.selectionIndex,
            "case \(testCase.id): solver selection", file: file, line: line
        )
        XCTAssertEqual(
            result.excludedCandidateCount, testCase.expected.excludedCandidates ?? 0,
            "case \(testCase.id): solver excluded candidate count", file: file, line: line
        )
        if testCase.expected.selectionIndex == nil {
            XCTAssertEqual(result.unmatchedCellCount, 1, "case \(testCase.id): unmatched cell", file: file, line: line)
        }
    }

    // MARK: - Corpus hygiene

    func testCorpusLoadsFromACommittedLocation() throws {
        let (url, corpus) = try Self.loadCorpus()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(corpus.version, 1, "unsupported corpus schema version")
        XCTAssertFalse(corpus.cases.isEmpty)
    }

    func testCorpusCaseIDsAreUnique() throws {
        let (_, corpus) = try Self.loadCorpus()
        let ids = corpus.cases.map(\.id)

        XCTAssertEqual(Set(ids).count, ids.count, "corpus case ids must be unique")
    }

    func testCorpusCasesAreWellFormed() throws {
        let (_, corpus) = try Self.loadCorpus()

        for testCase in corpus.cases {
            XCTAssertFalse(testCase.palette.isEmpty, "case \(testCase.id): palette must not be empty")
            if let selection = testCase.expected.selectionIndex {
                XCTAssertTrue(
                    testCase.palette.indices.contains(selection),
                    "case \(testCase.id): selection index \(selection) out of range"
                )
            }
            let weights = try Self.makeWeights(testCase.weights)
            XCTAssertFalse(weights.activeConditions.isEmpty, "case \(testCase.id): needs a weight > 0")
            for condition in weights.activeConditions {
                XCTAssertNotNil(testCase.target[condition.rawValue], "case \(testCase.id): target missing active channel \(condition.rawValue)")
            }
            _ = try testCase.palette.map(Self.makePaletteColor)
            _ = try Self.makeTarget(testCase.target)
        }
    }

    func testCorpusKeepsTieExclusionAndWeightHandlingCoverage() throws {
        let (_, corpus) = try Self.loadCorpus()

        XCTAssertGreaterThan(
            corpus.cases.filter { $0.expected.tie == true }.count, 1,
            "corpus must keep multiple tie cases"
        )
        XCTAssertTrue(
            corpus.cases.contains { ($0.expected.excludedCandidates ?? 0) > 0 },
            "corpus must keep cases where a missing measurement excludes a candidate"
        )
        XCTAssertTrue(
            corpus.cases.contains { $0.expected.selectionIndex == nil },
            "corpus must keep an all-candidates-excluded case"
        )
        XCTAssertTrue(
            corpus.cases.contains { testCase in
                let active = Set(testCase.weights.filter { $0.value > 0 }.keys)
                return testCase.palette.contains { !Set($0.responses.keys).isSubset(of: active) }
            },
            "corpus must keep a case with a measured channel at weight 0 (not required, not scored)"
        )
    }

    func testCorpusKeepsWeightFlipPair() throws {
        let (_, corpus) = try Self.loadCorpus()

        var bySignature: [String: [Corpus.Case]] = [:]
        for testCase in corpus.cases {
            bySignature[caseSignature(testCase), default: []].append(testCase)
        }

        let flips = bySignature.values.filter { group in
            Set(group.map { weightSignature($0.weights) }).count > 1
                && Set(group.compactMap(\.expected.selectionIndex)).count > 1
        }
        XCTAssertFalse(
            flips.isEmpty,
            "corpus must keep a same-palette/same-target pair whose weights flip the selection"
        )
    }

    private func caseSignature(_ testCase: Corpus.Case) -> String {
        let target = testCase.target.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return "\(testCase.palette.map(\.id))|\(target)"
    }

    private func weightSignature(_ weights: [String: Double]) -> String {
        weights.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    // MARK: - Loader

    func testCorpusLookupOrderCoversOverrideUpstreamCopyAndFixture() {
        let locations = Self.corpusLocations(
            environment: ["PARITY_CORPUS_PATH": "/tmp/overridden-corpus.json"],
            repositoryRoot: URL(fileURLWithPath: "/repo")
        )

        XCTAssertEqual(locations.map(\.path), [
            "/tmp/overridden-corpus.json",
            "/repo/color_matching/priv/solver_parity_corpus.json",
            Self.bundledFixtureURL.path
        ])
    }
}
