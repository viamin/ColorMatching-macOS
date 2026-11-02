import Foundation

/// Decoded form of the `color_matching` solver parity corpus.
///
/// The corpus is the golden-vector contract shared with the Elixir server
/// (`ColorMatching.WeightedSquaredError` + earliest-index-wins selection).
/// The bytes live at `Fixtures/parity/v1/corpus.json` in this test target and
/// are refreshed from `viamin/color_matching` `priv/parity/v1/corpus.json` —
/// see `docs/solver-parity-corpus.md` for the refresh procedure.
struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
    let scenarios: [Scenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case scorer
        case selection
        case missingPolicy = "missing_policy"
        case lightSources = "light_sources"
        case scenarios
    }

    func scenario(id: String) -> Scenario? {
        scenarios.first { $0.id == id }
    }

    /// One replayable scenario: inputs (`weights`, `target`, `palette`) plus
    /// the server-computed `expected` outcome.
    struct Scenario: Decodable {
        let id: String
        let description: String
        let weights: [String: Double]
        let target: Vector
        let palette: [Vector]
        let expected: Expected
    }

    /// A target or candidate response vector. A channel absent from
    /// `channels` is *missing* — never zero brightness.
    struct Vector: Decodable {
        let index: Int?
        let hexColor: String
        let channels: [String: Double]

        enum CodingKeys: String, CodingKey {
            case index
            case hexColor = "hex_color"
            case channels
        }
    }

    /// The server's expected outcome for one scenario.
    struct Expected: Decodable {
        let scores: [CandidateScore]
        let selectedIndex: Int?
        let selectedHexColor: String?
        let error: Double?
        let tieBroke: Bool?
        let tiedIndices: [Int]

        enum CodingKeys: String, CodingKey {
            case scores
            case selectedIndex = "selected_index"
            case selectedHexColor = "selected_hex_color"
            case error
            case tieBroke = "tie_broke"
            case tiedIndices = "tied_indices"
        }
    }

    /// Per-candidate outcome: a finite score or the `"excluded"` marker.
    struct CandidateScore: Decodable {
        let index: Int
        let outcome: Outcome

        enum CodingKeys: String, CodingKey {
            case index
            case outcome = "score"
        }

        enum Outcome: Decodable, Equatable {
            case score(Double)
            case excluded

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let marker = try? container.decode(String.self), marker == "excluded" {
                    self = .excluded
                } else {
                    self = .score(try container.decode(Double.self))
                }
            }
        }
    }
}

enum ParityCorpusFixture {
    /// Absolute URL of the committed corpus fixture, resolved relative to this
    /// source file so it works under both `swift test` and Xcode without a
    /// bundle resource declaration.
    static var url: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parity/v1/corpus.json")
    }

    static func load() throws -> ParityCorpus {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ParityCorpus.self, from: data)
    }
}
