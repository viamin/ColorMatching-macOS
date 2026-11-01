import Foundation
@testable import ColorComposerCore

/// Per-candidate expectation from the parity corpus: either a numeric
/// weighted-squared-error total or the `excluded` marker.
enum ParityCorpusScore: Equatable {
    case score(Double)
    case excluded
}

extension ParityCorpusScore: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let total = try? container.decode(Double.self) {
            self = .score(total)
        } else if (try? container.decode(String.self)) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Score must be a number or the string \"excluded\"."
            )
        }
    }
}

/// Codable mirror of the solver parity corpus committed by the
/// `color_matching` server (viamin/color_matching#111).
///
/// Upstream generates the corpus deterministically with `mix parity.generate`
/// (`ColorMatching.Parity.Corpus`); this side only reads it. Key style is
/// snake_case on the wire, decoded with `convertFromSnakeCase`.
struct ParityCorpus: Decodable {
    struct Entry: Decodable, Equatable {
        /// Palette position; `nil` for targets.
        let index: Int?
        let hexColor: String
        /// Measured brightness per light source; absent key = unmeasured.
        let channels: [String: Double]
    }

    struct ExpectedScore: Decodable, Equatable {
        let index: Int
        let score: ParityCorpusScore
    }

    struct Expected: Decodable, Equatable {
        let scores: [ExpectedScore]
        let selectedIndex: Int?
        let selectedHexColor: String?
        let error: Double?
        let tieBroke: Bool?
        let tiedIndices: [Int]

        /// Expected outcome for the palette candidate at `index`.
        func score(for index: Int) -> ParityCorpusScore? {
            scores.first { $0.index == index }?.score
        }
    }

    struct Scenario: Decodable, Equatable {
        let id: String
        let description: String
        /// Weight per light source; unknown sources must be ignored.
        let weights: [String: Double]
        let target: Entry
        let palette: [Entry]
        let expected: Expected
    }

    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
    let scenarios: [Scenario]
}

/// Locates and decodes the committed corpus fixture.
///
/// The fixture is copied byte-for-byte from the server repository's
/// `priv/parity/v1/corpus.json` — see `docs/solver-parity-corpus.md` for how
/// to refresh it.
enum ParityCorpusFixture {
    /// Corpus semantics this suite understands. Bump when the upstream
    /// `algorithm_version` moves and expectations are re-baselined.
    static let supportedAlgorithmVersion = 1

    static let relativePath = "Fixtures/parity/v1/corpus.json"

    static func load() throws -> ParityCorpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: data)
    }
}
