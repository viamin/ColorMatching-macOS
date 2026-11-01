import Foundation
import XCTest
@testable import ColorComposerCore

/// Offline-fallback characterization for `ProfileColorCache` (issue #39).
///
/// The generated OpenAPI client migration may not disturb the disk cache:
/// per-(server, profile) entries — written exactly as the API client decoded
/// them — must keep serving the offline flow: cached colors load when the
/// server is unreachable, the fetch date survives for the offline-stale
/// badge, and the cached palette still solves compositions. Cross-server
/// isolation and cache-integrity edge cases are covered exhaustively in
/// `ProfileColorCacheTests`; these tests pin the end-to-end offline path the
/// migration touches.
final class ProfileColorCacheMigrationTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileColorCacheMigrationTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func decodeEnvelope(_ json: String) throws -> ColorsResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ColorsResponse.self, from: Data(json.utf8))
    }

    private func colorsEnvelope() throws -> ColorsResponse {
        try decodeEnvelope(
            """
            {
              "printer_profile": {
                "id": 4, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"
              },
              "colors": [
                {"id": 11, "hex": "#111111", "rgb": {"r": 17, "g": 17, "b": 17},
                 "responses": {"red": {"brightness": 0.1}, "green": {"brightness": 0.1}}},
                {"id": 12, "hex": "#eeeeee", "rgb": {"r": 238, "g": 238, "b": 238},
                 "responses": {"red": {"brightness": 0.9}, "green": {"brightness": 0.9}}}
              ]
            }
            """
        )
    }

    /// The full offline path the app ships: a fetch cached as the API client
    /// decoded it, then read back when the server is unreachable, still
    /// yields a palette the solver can compose with.
    func testOfflineReadOfACachedFetchStillSolvesCompositions() throws {
        let envelope = try colorsEnvelope()
        let cache = ProfileColorCache(directory: directory)
        try cache.store(CachedProfileColors(
            serverBaseUrl: "http://localhost:4000",
            profileId: 4,
            profile: envelope.printerProfile,
            colors: envelope.colors,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        // Server down: same server (harmless trailing-slash spelling), read serves the cache.
        let cached = try XCTUnwrap(cache.entry(for: 4, serverBaseUrl: "http://localhost:4000/"))
        let palette = cached.domainColors
        XCTAssertEqual(palette.map(\.id), [11, 12])

        let grid = BrightnessGrid(width: 2, height: 1, values: [0.0, 1.0])
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: grid, .green: grid],
            weights: ChannelWeights(red: 1, green: 1)
        )

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), 0) // dark target -> dark cached color
        XCTAssertEqual(result.colorIndex(x: 1, y: 0), 1) // bright target -> bright cached color
    }

    /// The offline-stale badge renders `fetchedAt`; the exact timestamp must
    /// survive the disk round trip.
    func testFetchedAtSurvivesDiskRoundTripExactlyForStaleBadge() throws {
        let cache = ProfileColorCache(directory: directory)
        let stamp = Date(timeIntervalSince1970: 1_700_000_123)
        try cache.store(CachedProfileColors(
            serverBaseUrl: "http://localhost:4000",
            profileId: 8,
            profile: nil,
            colors: [],
            fetchedAt: stamp
        ))

        let cached = try XCTUnwrap(cache.entry(for: 8, serverBaseUrl: "http://localhost:4000"))
        XCTAssertEqual(cached.fetchedAt, stamp)
    }

    /// The offline profile picker falls back to `allEntries`; entries cached
    /// from a live fetch must stay listed with servable colors.
    func testAllEntriesServesTheCachedProfileFallback() throws {
        let cache = ProfileColorCache(directory: directory)
        let envelope = try colorsEnvelope()
        try cache.store(CachedProfileColors(
            serverBaseUrl: "http://localhost:4000",
            profileId: 4,
            profile: envelope.printerProfile,
            colors: envelope.colors,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        let entries = cache.allEntries(serverBaseUrl: "http://localhost:4000")

        XCTAssertEqual(entries.map(\.profileId), [4])
        XCTAssertTrue(entries.first?.hasServableColors ?? false)
        XCTAssertEqual(entries.first?.domainColors.count, 2)
    }
}
