import Foundation
import XCTest
@testable import ColorComposerCore

/// Loads the committed solver parity corpus and asserts that
/// `WeightedSquaredErrorScorer` — driven by `CompositionSolver`, exactly as the
/// app uses it — reproduces every expected selection, including:
///
/// - ties resolved to the earliest palette entry (the policy shared with the
///   Elixir `IlluminantMatching.best_match/4`),
/// - exclusions: a color missing a measurement for an active channel is
///   excluded, never treated as zero brightness,
/// - weight handling: per-channel weights scale contributions and can flip
///   the selection.
///
/// Corpus location and format: `Tests/ColorComposerCoreTestFixtures/solver_parity/`
/// (see `docs/solver-parity-corpus.md`). Every `*.json` file in that directory
/// is loaded, so corpus drops generated upstream (viamin/color_matching#111)
/// are consumed without test changes.
final class SolverParityCorpusTests: XCTestCase {
    private static let corpusFormat = "color-matching-solver-parity/1"
    private static let scoreAccuracy = 1e-9
    private static let tieAccuracy = 1e-12

    // MARK: - Corpus discovery

    private static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ColorComposerCoreTests/
            .deletingLastPathComponent() // Tests/
            .appendingPathComponent("ColorComposerCoreTestFixtures", isDirectory: true)
            .appendingPathComponent("solver_parity", isDirectory: true)
    }

    private static func corpusFileURLs() throws -> [URL] {
        let directory = fixturesDirectory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CorpusError.corpusDirectoryMissing(directory.path)
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else {
            throw CorpusError.corpusDirectoryEmpty(directory.path)
        }
        return files
    }

    private static func decodeCorpus(at fileURL: URL) throws -> ParityCorpusFile {
        try JSONDecoder().decode(ParityCorpusFile.self, from: Data(contentsOf: fileURL))
    }

    // MARK: - Corpus presence and format

    func testCorpusDirectoryIsCommittedWithAtLeastOneFile() throws {
        let files = try Self.corpusFileURLs()
        XCTAssertGreaterThanOrEqual(
            files.count, 1,
            "solver parity corpus directory must contain at least one .json corpus file"
        )
    }

    func testCorpusFilesDeclareSupportedFormat() throws {
        for url in try Self.corpusFileURLs() {
            let file = try Self.decodeCorpus(at: url)
            XCTAssertEqual(
                file.format, Self.corpusFormat,
                "\(url.lastPathComponent): unsupported corpus format \(file.format)"
            )
        }
    }

    // MARK: - Parity assertions

    func testSolverSelectionsMatchExpectedOutputs() throws {
        for caseRun in try allRuns() {
            let expected = caseRun.parityCase.expected
            let selectedIndex = caseRun.result.colorIndex(x: 0, y: 0)
            let selectedID = selectedIndex.map { caseRun.result.palette[$0].id }

            if expected.unmatched {
                XCTAssertNil(
                    selectedIndex,
                    "[case \(caseRun.parityCase.id)] expected every candidate to be excluded " +
                        "(unmatched target), but selected \(selectedID.map(String.init) ?? "nil")"
                )
                continue
            }

            guard let expectedID = expected.selectedID else {
                XCTFail("[case \(caseRun.parityCase.id)] corpus entry must specify selected_id or unmatched: true")
                continue
            }
            XCTAssertEqual(
                selectedID, expectedID,
                "[case \(caseRun.parityCase.id)] WeightedSquaredErrorScorer selection mismatch"
            )
        }
    }

    func testExpectedScoresMatchExactly() throws {
        for caseRun in try allRuns() {
            guard let expectedScore = caseRun.parityCase.expected.score else { continue }
            XCTAssertEqual(
                caseRun.result.error(x: 0, y: 0), expectedScore, accuracy: Self.scoreAccuracy,
                "[case \(caseRun.parityCase.id)] selected-candidate score mismatch"
            )
        }
    }

    func testTiedCandidatesScoreIdenticallyAndEarliestWins() throws {
        let scorer = WeightedSquaredErrorScorer()
        for caseRun in try allRuns() {
            guard let tiedIDs = caseRun.parityCase.expected.tiedIDs, tiedIDs.count > 1 else { continue }
            let tiedEntries = caseRun.palette.enumerated().filter { tiedIDs.contains($0.element.id) }
            XCTAssertGreaterThanOrEqual(
                tiedEntries.count, tiedIDs.count,
                "[case \(caseRun.parityCase.id)] tied_ids reference colors missing from the palette"
            )

            var tiedScores: [Double] = []
            for (_, color) in tiedEntries {
                guard case .score(let value) = scorer.score(
                    candidate: color, target: caseRun.target, weights: caseRun.weights
                ) else {
                    XCTFail("[case \(caseRun.parityCase.id)] tied candidate \(color.id) unexpectedly excluded")
                    continue
                }
                tiedScores.append(value)
            }
            if let firstScore = tiedScores.first {
                for value in tiedScores {
                    XCTAssertEqual(
                        value, firstScore, accuracy: Self.tieAccuracy,
                        "[case \(caseRun.parityCase.id)] declared tied candidates must score identically"
                    )
                }
            }
            if let earliest = tiedEntries.first {
                XCTAssertEqual(
                    caseRun.result.colorIndex(x: 0, y: 0), earliest.offset,
                    "[case \(caseRun.parityCase.id)] ties must resolve to the earliest palette entry " +
                        "(expected color \(earliest.element.id))"
                )
            }
        }
    }

    // MARK: - Case execution

    private struct CaseRun {
        let parityCase: ParityCase
        let palette: [PaletteColor]
        let weights: ChannelWeights
        let target: TargetResponseVector
        let result: CompositionResult
    }

    private func allRuns() throws -> [CaseRun] {
        var caseRuns: [CaseRun] = []
        for url in try Self.corpusFileURLs() {
            let corpus = try Self.decodeCorpus(at: url)
            XCTAssertEqual(
                corpus.format, Self.corpusFormat,
                "unsupported corpus format in \(url.lastPathComponent): \(corpus.format)"
            )
            for parityCase in corpus.cases {
                do {
                    caseRuns.append(try run(parityCase))
                } catch {
                    XCTFail("[case \(parityCase.id)] malformed corpus case: \(error)")
                }
            }
        }
        return caseRuns
    }

    private func run(_ parityCase: ParityCase) throws -> CaseRun {
        let weights = try makeWeights(parityCase.weights, caseID: parityCase.id)
        guard !weights.activeConditions.isEmpty else {
            throw CorpusError.noActiveWeight(parityCase.id)
        }
        let palette = try makePalette(parityCase.palette, caseID: parityCase.id)
        let (target, grids) = try makeTarget(parityCase.target, weights: weights, caseID: parityCase.id)
        let solver = CompositionSolver(scorer: WeightedSquaredErrorScorer())
        let result = try solver.solve(palette: palette, sourceGrids: grids, weights: weights)
        return CaseRun(
            parityCase: parityCase, palette: palette, weights: weights, target: target, result: result
        )
    }

    private func makeWeights(_ raw: [String: Double], caseID: String) throws -> ChannelWeights {
        var weights = ChannelWeights()
        for (key, value) in raw.sorted(by: { $0.key < $1.key }) {
            guard let condition = LightingCondition(rawValue: key) else {
                throw CorpusError.unknownLightSource(key: key, context: "weights of case \(caseID)")
            }
            switch condition {
            case .white: weights.white = value
            case .red: weights.red = value
            case .green: weights.green = value
            case .blue: weights.blue = value
            case .lps: weights.lps = value
            }
        }
        return weights
    }

    private func makePalette(
        _ raw: [ParityCase.CorpusColor], caseID: String
    ) throws -> [PaletteColor] {
        guard !raw.isEmpty else { throw CorpusError.emptyPalette(caseID) }
        return try raw.map { entry in
            guard let rgb = RGBColor(hex: entry.hex) else {
                throw CorpusError.malformedHex(hex: entry.hex, colorID: entry.id)
            }
            var responses: [LightingCondition: IlluminationResponse] = [:]
            for (key, brightness) in entry.responses {
                guard let condition = LightingCondition(rawValue: key) else {
                    throw CorpusError.unknownLightSource(
                        key: key, context: "responses of color \(entry.id) in case \(caseID)"
                    )
                }
                responses[condition] = IlluminationResponse(brightness: brightness)
            }
            return PaletteColor(id: entry.id, name: entry.name, hex: entry.hex, rgb: rgb, responses: responses)
        }
    }

    private func makeTarget(
        _ raw: [String: Double], weights: ChannelWeights, caseID: String
    ) throws -> (TargetResponseVector, [LightingCondition: BrightnessGrid]) {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in raw {
            guard let condition = LightingCondition(rawValue: key) else {
                throw CorpusError.unknownLightSource(key: key, context: "target of case \(caseID)")
            }
            brightness[condition] = value
        }
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for (condition, _) in weights.activeEntries {
            guard let value = brightness[condition] else {
                throw CorpusError.targetMissingActiveCondition(condition, caseID: caseID)
            }
            grids[condition] = BrightnessGrid(width: 1, height: 1, values: [value])
        }
        return (TargetResponseVector(brightness), grids)
    }

    // MARK: - Corpus wire model

    private struct ParityCorpusFile: Decodable {
        let format: String
        let cases: [ParityCase]
    }

    private struct ParityCase: Decodable {
        let id: String
        let description: String?
        let weights: [String: Double]
        let palette: [CorpusColor]
        let target: [String: Double]
        let expected: Expected

        enum CodingKeys: String, CodingKey {
            case id, description, weights, palette, target, expected
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            weights = try container.decodeIfPresent([String: Double].self, forKey: .weights) ?? [:]
            palette = try container.decode([CorpusColor].self, forKey: .palette)
            target = try container.decodeIfPresent([String: Double].self, forKey: .target) ?? [:]
            expected = try container.decode(Expected.self, forKey: .expected)
        }

        struct CorpusColor: Decodable {
            let id: Int
            let name: String?
            let hex: String
            let responses: [String: Double]
        }

        struct Expected: Decodable {
            let selectedID: Int?
            let score: Double?
            let tiedIDs: [Int]?
            let unmatched: Bool

            enum CodingKeys: String, CodingKey {
                case selectedID = "selected_id"
                case score
                case tiedIDs = "tied_ids"
                case unmatched
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                selectedID = try container.decodeIfPresent(Int.self, forKey: .selectedID)
                score = try container.decodeIfPresent(Double.self, forKey: .score)
                tiedIDs = try container.decodeIfPresent([Int].self, forKey: .tiedIDs)
                unmatched = try container.decodeIfPresent(Bool.self, forKey: .unmatched) ?? false
            }
        }
    }

    // MARK: - Corpus errors

    private enum CorpusError: Error, CustomStringConvertible {
        case corpusDirectoryMissing(String)
        case corpusDirectoryEmpty(String)
        case unknownLightSource(key: String, context: String)
        case malformedHex(hex: String, colorID: Int)
        case targetMissingActiveCondition(LightingCondition, caseID: String)
        case noActiveWeight(String)
        case emptyPalette(String)

        var description: String {
            switch self {
            case .corpusDirectoryMissing(let path):
                return "solver parity corpus directory is missing — commit corpus JSON under " +
                    "\(path) (see docs/solver-parity-corpus.md)"
            case .corpusDirectoryEmpty(let path):
                return "solver parity corpus directory contains no .json files — expected the corpus " +
                    "from viamin/color_matching#111 under \(path)"
            case .unknownLightSource(let key, let context):
                return "unknown light source \"\(key)\" in \(context); expected one of " +
                    "\(LightingCondition.all.map(\.rawValue))"
            case .malformedHex(let hex, let colorID):
                return "color \(colorID) has malformed hex \"\(hex)\"; expected #RRGGBB"
            case .targetMissingActiveCondition(let condition, let caseID):
                return "case \(caseID) target lacks a value for active condition \(condition.rawValue)"
            case .noActiveWeight(let caseID):
                return "case \(caseID) has no channel with weight > 0; at least one is required"
            case .emptyPalette(let caseID):
                return "case \(caseID) has an empty palette; at least one candidate is required"
            }
        }
    }
}
