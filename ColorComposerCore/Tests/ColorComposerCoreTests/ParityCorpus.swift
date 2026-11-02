import Foundation

/// Errors raised while locating, decoding, or validating a solver parity corpus.
enum ParityCorpusError: Error, CustomStringConvertible {
    case corpusNotFound(searched: [String])
    case unsupportedVersion(Int)
    case unknownLightSource(key: String, caseName: String)
    case noActiveWeights(caseName: String)
    case targetMissingActiveCondition(condition: String, caseName: String)
    case emptyPalette(caseName: String)
    case duplicatePaletteID(id: Int, caseName: String)
    case unparseableHex(id: Int, caseName: String)
    case unknownPaletteID(id: Int, caseName: String)
    case missingExpectedScore(caseName: String)

    var description: String {
        switch self {
        case .corpusNotFound(let searched):
            return "No parity corpus found. Searched: \(searched.joined(separator: ", "))"
        case .unsupportedVersion(let v):
            return "Corpus schema version \(v) is not supported (expected 1)."
        case .unknownLightSource(let key, let name):
            return "Case '\(name)' uses unknown light source '\(key)'."
        case .noActiveWeights(let name):
            return "Case '\(name)' has no condition with weight > 0."
        case .targetMissingActiveCondition(let condition, let name):
            return "Case '\(name)' target is missing the active condition '\(condition)'."
        case .emptyPalette(let name):
            return "Case '\(name)' has an empty palette."
        case .duplicatePaletteID(let id, let name):
            return "Case '\(name)' repeats palette id \(id)."
        case .unparseableHex(let id, let name):
            return "Case '\(name)' palette color \(id) has a hex string the client cannot parse."
        case .unknownPaletteID(let id, let name):
            return "Case '\(name)' expected block references palette id \(id), which does not exist."
        case .missingExpectedScore(let name):
            return "Case '\(name)' expects a selection but records no score."
        }
    }
}

/// A solver parity corpus published by `color_matching`
/// (viamin/color_matching#111): a versioned list of selection cases — palette,
/// weights, one target vector, and the expected `WeightedSquaredError`
/// selection — so this client can prove it selects exactly what the Elixir
/// `WeightedSquaredError` solver selects, ties and exclusions included.
///
/// JSON keys are snake_case, matching the server's wire conventions:
///
/// ```json
/// {
///   "version": 1,
///   "cases": [{
///     "name": "exact_tie_breaks_to_earliest_candidate",
///     "weights": { "red": 1.0 },
///     "palette": [
///       { "id": 1, "name": "shadow", "hex": "#404040",
///         "responses": { "red": 0.25 } }
///     ],
///     "target": { "red": 0.5 },
///     "expected": {
///       "selected_id": 1, "score": 0.0625,
///       "tie_ids": [1, 2], "excluded_ids": []
///     }
///   }]
/// }
/// ```
///
/// Semantics asserted by the runner (see `SolverParityCorpusTests`):
/// - `selected_id` — the palette id the solver must select for `target`;
///   `null` when every candidate is excluded (cell left unmatched).
/// - `tie_ids` — every id achieving the minimum score; `selected_id` must be
///   the earliest of them in palette order (the shared earliest-wins policy).
/// - `excluded_ids` — exactly the ids excluded for missing a measurement on a
///   condition with weight > 0. Missing is never zero brightness.
struct ParityCorpus: Codable {
    let version: Int
    /// Where the corpus came from (upstream commit / PR), for provenance.
    let source: String?
    let cases: [Case]

    struct Case: Codable {
        let name: String
        let description: String?
        /// Light-source string → weight. Omitted or zero-weight conditions are
        /// ignored by the scorer (and must not be required).
        let weights: [String: Double]
        let palette: [PaletteEntry]
        /// Light-source string → target brightness for that condition.
        let target: [String: Double]
        let expected: Expected
    }

    struct PaletteEntry: Codable {
        let id: Int
        let name: String?
        let hex: String
        /// Light-source string → measured brightness. Absent = unmeasured.
        let responses: [String: Double]
    }

    struct Expected: Codable {
        /// The id that must be selected, or null when all candidates are
        /// excluded.
        let selectedId: Int?
        /// The `WeightedSquaredError` score of the selection; null when
        /// nothing is selectable.
        let score: Double?
        /// All ids achieving the minimum score (defaults to [selected_id]).
        let tieIds: [Int]?
        /// Exactly the ids excluded for missing required measurements
        /// (defaults to []).
        let excludedIds: [Int]?
    }

    // MARK: - Decoding

    static func decode(from data: Data) throws -> ParityCorpus {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let corpus = try decoder.decode(ParityCorpus.self, from: data)
        guard corpus.version == 1 else { throw ParityCorpusError.unsupportedVersion(corpus.version) }
        return corpus
    }

    // MARK: - Locating the committed corpus

    /// Candidate locations of the vendored corpus, in resolution order, for a
    /// repository root. The primary documented location comes first; the
    /// remainder keep the loader working if the vendored copy moves.
    static func vendoredLocations(repoRoot: URL) -> [URL] {
        [
            repoRoot.appendingPathComponent("color_matching/parity_corpus.json"),
            repoRoot.appendingPathComponent("color_matching/test/solver_parity_corpus.json"),
            repoRoot.appendingPathComponent("ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity_corpus.json"),
            repoRoot.appendingPathComponent("parity_corpus.json")
        ]
    }

    /// The repository root derived from a test source file that lives at
    /// `<root>/ColorComposerCore/Tests/ColorComposerCoreTests/<file>.swift`.
    static func repoRoot(filePath: StaticString) -> URL {
        let file = URL(fileURLWithPath: "\(filePath)")
        return file.deletingLastPathComponent()   // …/ColorComposerCoreTests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // …/ColorComposerCore
            .deletingLastPathComponent()          // repo root
    }

    /// Loads the committed corpus. Resolution order: the
    /// `COLOR_MATCHING_PARITY_CORPUS` environment override, then
    /// `vendoredLocations`. Throws `ParityCorpusError.corpusNotFound` when no
    /// candidate exists — the parity test surfaces that as a failure so a
    /// missing corpus can never pass silently.
    static func loadVendored(filePath: StaticString = #filePath) throws -> (corpus: ParityCorpus, origin: URL) {
        let root = repoRoot(filePath: filePath)
        var candidates: [URL]
        if let override = ProcessInfo.processInfo.environment["COLOR_MATCHING_PARITY_CORPUS"], !override.isEmpty {
            candidates = [URL(fileURLWithPath: override)]
        } else {
            candidates = vendoredLocations(repoRoot: root)
        }

        for url in candidates {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let data = try Data(contentsOf: url)
            return try (decode(from: data), url)
        }
        throw ParityCorpusError.corpusNotFound(searched: candidates.map(\.path))
    }
}
