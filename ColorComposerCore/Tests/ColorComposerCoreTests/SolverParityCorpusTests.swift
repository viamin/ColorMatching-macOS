import Foundation
import XCTest
@testable import ColorComposerCore

/// Solver parity against the committed corpus (viamin/color_matching#111).
///
/// The corpus lives at `Fixtures/solver_parity_corpus.json` next to this file
/// and pins `WeightedSquaredErrorScorer` selections exactly — including ties
/// (earliest candidate wins), exclusions (missing measurement on an active
/// channel), measured-zero vs missing, and weight handling. Refreshing the
/// corpus is documented in `docs/solver-parity-corpus.md`.
final class SolverParityCorpusTests: XCTestCase {
    private var corpus: ParityCorpus!

    override func setUpWithError() throws {
        try super.setUpWithError()
        corpus = try ParityCorpus.load()
    }

    func testCorpusLoadsAndDeclaresUpstreamSource() throws {
        XCTAssertGreaterThanOrEqual(corpus.cases.count, 1, "parity corpus must contain cases")
        XCTAssertEqual(corpus.schema, 1, "loader supports schema 1 only; extend it when the format changes")
        XCTAssertEqual(corpus.algorithm, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.source?.repo, "viamin/color_matching")
    }

    func testCorpusHasUniqueCaseIdentifiers() {
        let identifiers = corpus.cases.map(\.id)
        XCTAssertEqual(identifiers.count, Set(identifiers).count, "case ids must be unique")
    }

    func testCorpusCoversTiesExclusionsAndWeightBehavior() {
        let tags = Set(corpus.cases.flatMap { $0.tags ?? [] })
        XCTAssertTrue(tags.contains("tie"), "corpus must cover tie cases")
        XCTAssertTrue(tags.contains("exclusion"), "corpus must cover exclusion cases")
        XCTAssertTrue(tags.contains("zero-weight"), "corpus must cover zero-weight channel handling")
        XCTAssertTrue(tags.contains("measured-zero"), "corpus must distinguish measured zero from missing")
        XCTAssertTrue(tags.contains("weights"), "corpus must cover weight scaling")
    }

    func testSelectionsMatchCorpusExactly() throws {
        for parityCase in corpus.cases {
            try assertSelectionsMatch(case: parityCase)
        }
    }

    private func assertSelectionsMatch(case parityCase: ParityCorpus.Case) throws {
        let weights = try makeWeights(parityCase.weights, caseID: parityCase.id)
        let palette = try parityCase.palette.map { try makeColor($0, caseID: parityCase.id) }
        let (width, height) = try dimensions(of: parityCase)
        let grids = try makeGrids(for: parityCase, width: width, height: height)

        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: grids,
            weights: weights
        )

        let selectedIDs = result.colorIndices.map { $0.map { palette[$0].id } }
        XCTAssertEqual(
            selectedIDs, parityCase.expectedSelections,
            "\(parityCase.id): selections must match the corpus exactly"
        )

        if let expectedScores = parityCase.expectedScores {
            XCTAssertEqual(expectedScores.count, result.cellCount, "\(parityCase.id): score count mismatch")
            for (cell, expected) in expectedScores.enumerated() {
                if let expected {
                    XCTAssertEqual(
                        result.errors[cell], expected, accuracy: 1e-9,
                        "\(parityCase.id): score for cell \(cell) must match"
                    )
                } else {
                    XCTAssertTrue(
                        result.errors[cell].isInfinite,
                        "\(parityCase.id): unmatched cell \(cell) must record an infinite error"
                    )
                }
            }
        }

        if let expectedExcluded = parityCase.expectedExcludedCount {
            XCTAssertEqual(
                result.excludedCandidateCount, expectedExcluded,
                "\(parityCase.id): excluded candidate count must match"
            )
        }

        if parityCase.expectedSelections.contains(nil) {
            try assertEveryCandidateExcluded(for: parityCase, weights: weights, palette: palette)
        }
    }

    /// Cells can only be unmatched when every candidate is excluded under the
    /// corpus weights — verified straight through the scorer.
    private func assertEveryCandidateExcluded(
        for parityCase: ParityCorpus.Case,
        weights: ChannelWeights,
        palette: [PaletteColor]
    ) throws {
        let target = try makeTarget(parityCase.targets[0], caseID: parityCase.id, conditions: weights.activeConditions)
        let scorer = WeightedSquaredErrorScorer()
        for color in palette {
            XCTAssertEqual(
                scorer.score(candidate: color, target: target, weights: weights),
                .excluded,
                "\(parityCase.id): candidate \(color.id) must be excluded for the cell to be unmatched"
            )
        }
    }

    // MARK: - Corpus model

    private struct ParityCorpus: Codable {
        struct Source: Codable {
            let repo: String?
            let pull: Int?
            let note: String?
        }

        struct Case: Codable {
            struct Color: Codable {
                struct Response: Codable {
                    let brightness: Double
                }

                struct RGB: Codable {
                    let r: Int
                    let g: Int
                    let b: Int
                }

                let id: Int
                let name: String?
                let hex: String
                let rgb: RGB?
                let responses: [String: Response]
            }

            let id: String
            let description: String?
            let tags: [String]?
            let weights: [String: Double]
            let palette: [Color]
            let width: Int?
            let targets: [[String: Double]]
            let expectedSelections: [Int?]
            let expectedScores: [Double?]?
            let expectedExcludedCount: Int?

            enum CodingKeys: String, CodingKey {
                case id, description, tags, weights, palette, width, targets
                case expectedSelections = "expected_selections"
                case expectedScores = "expected_scores"
                case expectedExcludedCount = "expected_excluded_count"
            }
        }

        let schema: Int
        let algorithm: String
        let source: Source?
        let cases: [Case]

        static func load(file: StaticString = #filePath) throws -> ParityCorpus {
            let fixture = URL(fileURLWithPath: "\(file)", isDirectory: false)
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/solver_parity_corpus.json")
            let data = try Data(contentsOf: fixture)
            return try JSONDecoder().decode(ParityCorpus.self, from: data)
        }
    }

    // MARK: - Corpus → domain conversion

    private enum CorpusError: Error, CustomStringConvertible {
        case unknownCondition(String, caseID: String)
        case targetMissingCondition(LightingCondition, caseID: String)
        case unparseableHex(String, caseID: String)
        case indivisibleGrid(caseID: String, cells: Int, width: Int)

        var description: String {
            switch self {
            case .unknownCondition(let key, let caseID):
                return "\(caseID): unknown lighting condition \"\(key)\"; corpus keys must be white/red/green/blue/lps"
            case .targetMissingCondition(let condition, let caseID):
                return "\(caseID): target vector lacks active condition \(condition.rawValue)"
            case .unparseableHex(let hex, let caseID):
                return "\(caseID): palette hex \"\(hex)\" does not parse"
            case .indivisibleGrid(let caseID, let cells, let width):
                return "\(caseID): \(cells) targets do not divide evenly into width \(width)"
            }
        }
    }

    private func condition(forKey key: String, caseID: String) throws -> LightingCondition {
        guard let condition = LightingCondition(rawValue: key) else {
            throw CorpusError.unknownCondition(key, caseID: caseID)
        }
        return condition
    }

    private func makeWeights(_ dict: [String: Double], caseID: String) throws -> ChannelWeights {
        var weights = ChannelWeights()
        for (key, value) in dict {
            switch try condition(forKey: key, caseID: caseID) {
            case .white: weights.white = value
            case .red: weights.red = value
            case .green: weights.green = value
            case .blue: weights.blue = value
            case .lps: weights.lps = value
            }
        }
        return weights
    }

    private func makeColor(_ color: ParityCorpus.Case.Color, caseID: String) throws -> PaletteColor {
        let rgb: RGBColor
        if let dto = color.rgb {
            rgb = RGBColor(
                red: UInt8(clamping: dto.r),
                green: UInt8(clamping: dto.g),
                blue: UInt8(clamping: dto.b)
            )
        } else {
            guard let parsed = RGBColor(hex: color.hex) else {
                throw CorpusError.unparseableHex(color.hex, caseID: caseID)
            }
            rgb = parsed
        }
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, response) in color.responses {
            responses[try condition(forKey: key, caseID: caseID)] = IlluminationResponse(
                brightness: response.brightness
            )
        }
        return PaletteColor(id: color.id, name: color.name, hex: color.hex, rgb: rgb, responses: responses)
    }

    private func dimensions(of parityCase: ParityCorpus.Case) throws -> (width: Int, height: Int) {
        let width = parityCase.width ?? max(parityCase.targets.count, 1)
        guard parityCase.targets.count % width == 0 else {
            throw CorpusError.indivisibleGrid(
                caseID: parityCase.id, cells: parityCase.targets.count, width: width
            )
        }
        return (width, parityCase.targets.count / width)
    }

    private func makeGrids(
        for parityCase: ParityCorpus.Case,
        width: Int,
        height: Int
    ) throws -> [LightingCondition: BrightnessGrid] {
        let weights = try makeWeights(parityCase.weights, caseID: parityCase.id)
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for entry in weights.activeEntries {
            var values: [Double] = []
            values.reserveCapacity(parityCase.targets.count)
            for dict in parityCase.targets {
                let target = try makeTarget(dict, caseID: parityCase.id, conditions: [entry.condition])
                guard let value = target.value(for: entry.condition) else {
                    throw CorpusError.targetMissingCondition(entry.condition, caseID: parityCase.id)
                }
                values.append(value)
            }
            grids[entry.condition] = BrightnessGrid(width: width, height: height, values: values)
        }
        return grids
    }

    private func makeTarget(
        _ dict: [String: Double],
        caseID: String,
        conditions: [LightingCondition]
    ) throws -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in dict {
            brightness[try condition(forKey: key, caseID: caseID)] = value
        }
        for condition in conditions where brightness[condition] == nil {
            throw CorpusError.targetMissingCondition(condition, caseID: caseID)
        }
        return TargetResponseVector(brightness)
    }
}
