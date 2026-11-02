import Foundation
import XCTest
@testable import ColorComposerCore
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The `color_matching` server's golden-vector corpus for client/server
/// solver parity.
///
/// The committed fixture is a byte-for-byte copy of
/// `priv/parity/v1/corpus.json` in `viamin/color_matching`, generated there by
/// `mix parity.generate`. Every scenario carries the palette, the target
/// vector, the channel weights and the server's expected scores, selection,
/// error and tie-break evidence, so the client can replay them and prove it
/// still agrees with the server.
struct ParityCorpus: Decodable {
    /// Stamped by the server; bumped whenever its scoring semantics change.
    let algorithmVersion: Int
    /// Server module that produced the expectations.
    let scorer: String
    /// Tie-break policy the server applied.
    let selection: String
    /// Missing-measurement policy the server applied.
    let missingPolicy: String
    /// Light sources the server can measure.
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
}

extension ParityCorpus {
    /// One replayable scenario: inputs plus the server's expectations.
    struct Scenario: Decodable {
        let id: String
        let description: String
        /// Channel weights keyed by light source. Sources the app does not know
        /// (the server ignores them as well) are dropped.
        let weights: [String: Double]
        let target: Entry
        let palette: [Entry]
        let expected: Expectation

        enum CodingKeys: String, CodingKey {
            case id
            case description
            case weights
            case target
            case palette
            case expected
        }
    }

    /// One measured response vector (a palette color or the target).
    struct Entry: Decodable {
        /// Position in the scenario's palette; `nil` for the target.
        let index: Int?
        let hexColor: String
        /// Measured brightness per light source. A light source that is absent
        /// was never measured — it is *missing*, not zero.
        let channels: [String: Double]

        enum CodingKeys: String, CodingKey {
            case index
            case hexColor = "hex_color"
            case channels
        }
    }

    /// What the server expected the scenario to produce.
    struct Expectation: Decodable {
        let scores: [Score]
        let selectedIndex: Int?
        let selectedHexColor: String?
        let error: Double?
        /// `nil` when the server made no selection at all.
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

    /// One candidate's expected score; `score` is `nil` when the server
    /// excluded the candidate (the corpus writes the string `"excluded"`).
    struct Score: Decodable {
        let index: Int
        let score: Double?

        enum CodingKeys: String, CodingKey {
            case index
            case score
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            index = try container.decode(Int.self, forKey: .index)
            if let marker = try? container.decode(String.self, forKey: .score) {
                guard marker == "excluded" else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .score,
                        in: container,
                        debugDescription: "Unknown score marker \"\(marker)\"."
                    )
                }
                score = nil
            } else {
                score = try container.decode(Double.self, forKey: .score)
            }
        }
    }
}

// MARK: - Domain conversion

extension ParityCorpus.Entry {
    /// Measured brightness per lighting condition. Light sources the app does
    /// not know are ignored, mirroring the server's `filter_weights/1`.
    var brightnessByCondition: [LightingCondition: Double] {
        var result: [LightingCondition: Double] = [:]
        for (source, brightness) in channels {
            guard let condition = LightingCondition(rawValue: source) else { continue }
            result[condition] = brightness
        }
        return result
    }

    /// Measured responses keyed by lighting condition.
    var responses: [LightingCondition: IlluminationResponse] {
        brightnessByCondition.mapValues { IlluminationResponse(brightness: $0) }
    }
}

extension ParityCorpus.Scenario {
    /// The scenario's channel weights. Light sources outside the app's set are
    /// dropped — the server ignores them too, so both sides score identically.
    func channelWeights() -> ChannelWeights {
        ChannelWeights(
            white: weight(for: .white),
            red: weight(for: .red),
            green: weight(for: .green),
            blue: weight(for: .blue),
            lps: weight(for: .lps)
        )
    }

    /// The target vector. Channels the scenario does not measure stay absent,
    /// so "missing" is never confused with "measured as zero brightness".
    func targetVector() -> TargetResponseVector {
        TargetResponseVector(target.brightnessByCondition)
    }

    /// The scenario's palette as solver-ready colors, in corpus order.
    func paletteColors() -> [PaletteColor] {
        palette.enumerated().map { offset, entry in
            PaletteColor(
                id: offset,
                name: entry.hexColor,
                hex: entry.hexColor,
                rgb: RGBColor(hex: entry.hexColor) ?? RGBColor(red: 0, green: 0, blue: 0),
                responses: entry.responses
            )
        }
    }

    /// One-cell source grids holding the target brightness, so the app's real
    /// solver path can be replayed against the scenario's target.
    func sourceGrids() -> [LightingCondition: BrightnessGrid] {
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for condition in channelWeights().activeEntries.map(\.condition) {
            guard let value = target.channels[condition.rawValue] else { continue }
            grids[condition] = BrightnessGrid(width: 1, height: 1, values: [value])
        }
        return grids
    }

    /// `true` when the target measures every positive-weight channel. The
    /// solver always matches against a complete target, so scenarios whose
    /// target is missing a required channel can only be replayed through the
    /// scorer.
    var targetCoversActiveConditions: Bool {
        let weights = channelWeights()
        return weights.activeConditions.allSatisfy { target.channels[$0.rawValue] != nil }
    }

    /// Candidates the server excluded.
    var excludedIndices: [Int] {
        expected.scores.filter { $0.score == nil }.map(\.index)
    }

    private func weight(for condition: LightingCondition) -> Double {
        weights[condition.rawValue] ?? 0
    }
}

// MARK: - Fixture loading

/// Locates and decodes the committed parity corpus.
enum ParityCorpusLoader {
    enum LoaderError: Error, CustomStringConvertible {
        case fixtureNotFound([String])
        case unreadable(URL, Error)

        var description: String {
            switch self {
            case .fixtureNotFound(let searched):
                return """
                The parity corpus fixture was not found. Looked in:
                \(searched.map { "  - \($0)" }.joined(separator: "\n"))
                """
            case .unreadable(let url, let error):
                return "Could not read the parity corpus fixture at \(url.path): \(error)"
            }
        }
    }

    /// Location of the fixture, relative to the test sources (or to the test
    /// target directory, where the corpus is committed).
    static let fixtureRelativePath = "Fixtures/parity/v1/corpus.json"

    /// SHA-256 of the upstream fixture this copy was taken from
    /// (`priv/parity/v1/corpus.json` in `viamin/color_matching`). A different
    /// digest means the corpus was refreshed and every expectation in it may
    /// have moved.
    static let upstreamDigest = "7b7b4d904ff369e1f5be0ec3a994d96cc996056e856d86a2b764b83c050f8604"

    static func load() throws -> ParityCorpus {
        let url = try fixtureURL()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoaderError.unreadable(url, error)
        }
        return try JSONDecoder().decode(ParityCorpus.self, from: data)
    }

    /// The committed fixture's bytes, for digest checks.
    static func fixtureData() throws -> Data {
        try Data(contentsOf: try fixtureURL())
    }

    /// Hex-encoded SHA-256 of the given bytes, or `nil` where CryptoKit is
    /// unavailable (the digest check then does not run).
    static func digest(of data: Data) -> String? {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }

    static func fixtureURL() throws -> URL {
        let candidates = candidateURLs()
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw LoaderError.fixtureNotFound(candidates.map(\.path))
    }

    private static func candidateURLs() -> [URL] {
        var candidates: [URL] = []
        let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        // The lint harness reaches the sources through a symlink, so the same
        // locations are also tried with symlinks resolved.
        let resolvedDirectory = URL(fileURLWithPath: #filePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for directory in [sourceDirectory, resolvedDirectory] {
            // The fixture next to the test sources.
            candidates.append(directory.appendingPathComponent(fixtureRelativePath))
            // The fixture next to the test target directory, which is where
            // the corpus is committed.
            candidates.append(
                directory.deletingLastPathComponent().appendingPathComponent(fixtureRelativePath)
            )
        }
        // A copy bundled as a test resource, when the fixture is declared as one.
        let bundle = Bundle(for: ParityCorpusBundleAnchor.self)
        for resource in ["corpus", "parity/v1/corpus"] {
            if let url = bundle.url(forResource: resource, withExtension: "json") {
                candidates.append(url)
            }
        }
        return candidates
    }
}

/// Anchor class used to look the test bundle up for resource-based fixtures.
final class ParityCorpusBundleAnchor: NSObject {}
