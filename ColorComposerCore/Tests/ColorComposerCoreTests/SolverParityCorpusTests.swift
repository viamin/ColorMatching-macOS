import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(
        _ scenario: SolverParityCorpus.Scenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let scorer = WeightedSquaredErrorScorer()
        let weights = channelWeights(from: scenario.weights)
        let target = targetVector(from: scenario.target)
        let palette = try scenario.palette.enumerated().map { index, entry in
            try paletteColor(from: entry, index: index)
        }
        let results = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(results.count, scenario.expected.scores.count, scenario.id, file: file, line: line)
        for expectation in scenario.expected.scores {
            XCTAssertEqual(
                results[expectation.index],
                expectation.score.scorerResult,
                "\(scenario.id): candidate \(expectation.index)",
                file: file,
                line: line
            )
        }

        let selection = selectEarliestLowestScore(from: results)
        XCTAssertEqual(selection.index, scenario.expected.selectedIndex, scenario.id, file: file, line: line)
        XCTAssertEqual(selection.error, scenario.expected.error, scenario.id, file: file, line: line)
        XCTAssertEqual(selection.tiedIndices, scenario.expected.tiedIndices, scenario.id, file: file, line: line)
        XCTAssertEqual(selection.tiedIndices.count > 1, scenario.expected.tieBroke ?? false, scenario.id, file: file, line: line)
        XCTAssertEqual(
            selection.index.map { palette[$0].hex },
            scenario.expected.selectedHexColor,
            scenario.id,
            file: file,
            line: line
        )

        guard let sourceGrids = sourceGrids(for: target, weights: weights) else {
            XCTAssertNil(scenario.expected.selectedIndex, "\(scenario.id): missing active target channel", file: file, line: line)
            return
        }

        let solved = try CompositionSolver().solve(palette: palette, sourceGrids: sourceGrids, weights: weights)
        XCTAssertEqual(solved.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id, file: file, line: line)
        XCTAssertEqual(solved.error(x: 0, y: 0), scenario.expected.error ?? .infinity, scenario.id, file: file, line: line)
    }

    private func loadCorpus() throws -> SolverParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testDirectory.appendingPathComponent("Fixtures/solver-parity-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SolverParityCorpus.self, from: Data(contentsOf: url))
    }

    private func channelWeights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func targetVector(from entry: SolverParityCorpus.Entry) -> TargetResponseVector {
        TargetResponseVector(responses(from: entry.channels))
    }

    private func paletteColor(from entry: SolverParityCorpus.Entry, index: Int) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: entry.hexColor))
        return PaletteColor(
            id: index,
            hex: entry.hexColor,
            rgb: rgb,
            responses: responses(from: entry.channels)
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, brightness in
            LightingCondition(rawValue: key).map { ($0, IlluminationResponse(brightness: brightness)) }
        })
    }

    private func sourceGrids(
        for target: TargetResponseVector,
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid]? {
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for condition in weights.activeConditions {
            guard let brightness = target.value(for: condition) else { return nil }
            grids[condition] = BrightnessGrid(width: 1, height: 1, values: [brightness])
        }
        return grids
    }

    private func selectEarliestLowestScore(from results: [ScorerResult]) -> (index: Int?, error: Double?, tiedIndices: [Int]) {
        var selectedIndex: Int?
        var selectedError: Double?
        var tiedIndices: [Int] = []

        for (index, result) in results.enumerated() {
            guard case .score(let score) = result else { continue }
            guard let selectedError else {
                selectedIndex = index
                selectedError = score
                tiedIndices = [index]
                continue
            }
            if score < selectedError {
                selectedIndex = index
                selectedError = score
                tiedIndices = [index]
            } else if score == selectedError {
                tiedIndices.append(index)
            }
        }
        return (selectedIndex, selectedError, tiedIndices)
    }
}

private struct SolverParityCorpus: Decodable {
    let algorithmVersion: Int
    let selection: String
    let missingPolicy: String
    let scenarios: [Scenario]

    struct Scenario: Decodable {
        let id: String
        let weights: [String: Double]
        let target: Entry
        let palette: [Entry]
        let expected: Expected
    }

    struct Entry: Decodable {
        let hexColor: String
        let channels: [String: Double]
    }

    struct Expected: Decodable {
        let scores: [CandidateScore]
        let selectedIndex: Int?
        let selectedHexColor: String?
        let error: Double?
        let tieBroke: Bool?
        let tiedIndices: [Int]
    }

    struct CandidateScore: Decodable {
        let index: Int
        let score: Score
    }

    enum Score: Decodable {
        case excluded
        case value(Double)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                self = .value(value)
            } else if try container.decode(String.self) == "excluded" {
                self = .excluded
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
            }
        }

        var scorerResult: ScorerResult {
            switch self {
            case .excluded: return .excluded
            case .value(let value): return .score(value)
            }
        }
    }
}
