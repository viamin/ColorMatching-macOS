import XCTest
import ColorComposerCore
@testable import ColorMatching

/// Offline behavior of the palette catalog.
///
/// When the `color_matching` server cannot be reached the app must keep
/// working from its disk cache: the cached profile is offered in the picker
/// (the cached-profile fallback) and the cached colors are shown badged as
/// stale, with the date they were originally fetched.
///
/// The server is simulated by pointing the catalog at a closed local port, so
/// the request fails the way a transport failure fails in production.
@MainActor
final class ColorCatalogOfflineCacheTests: XCTestCase {
    /// A closed local port: connecting to it fails immediately.
    private let unreachableServer = "http://127.0.0.1:9"

    func testUnreachableServerOffersCachedProfileAndServesCachedColorsAsStale() async throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ColorCatalogOfflineCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let cache = ProfileColorCache(directory: cacheDirectory)
        try cache.store(CachedProfileColors(
            serverBaseUrl: unreachableServer,
            profileId: 42,
            profile: PrinterProfileDTO(
                id: 42,
                printerMakeModel: "Example Printer",
                paperType: "Matte",
                inkType: "Pigment"
            ),
            colors: [try Self.colorDTO()],
            fetchedAt: fetchedAt
        ))

        let catalog = ColorCatalog(cache: cache)
        catalog.configure(baseURL: URL(string: unreachableServer)!, token: nil)

        await catalog.refreshAll()

        XCTAssertEqual(
            catalog.printerProfiles.map(\.id),
            [42],
            "the cached profile is offered when the server cannot be reached"
        )
        XCTAssertTrue(
            catalog.isServingFromCache,
            "colors served from the cache are badged as offline-stale"
        )
        XCTAssertEqual(catalog.colors.map(\.hex), ["#00FFFF"])
        XCTAssertEqual(
            catalog.lastRefresh,
            fetchedAt,
            "the offline-stale badge shows the date the colors were fetched"
        )
    }

    /// The cached profile is only offered for the server that fetched it.
    func testCachedProfileIsNotOfferedForAnotherServer() async throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ColorCatalogOfflineCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let cache = ProfileColorCache(directory: cacheDirectory)
        try cache.store(CachedProfileColors(
            serverBaseUrl: unreachableServer,
            profileId: 42,
            profile: PrinterProfileDTO(
                id: 42,
                printerMakeModel: "Example Printer",
                paperType: "Matte",
                inkType: "Pigment"
            ),
            colors: [try Self.colorDTO()],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        let catalog = ColorCatalog(cache: cache)
        catalog.configure(baseURL: URL(string: "http://127.0.0.1:10")!, token: nil)

        await catalog.refreshAll()

        XCTAssertTrue(
            catalog.printerProfiles.isEmpty,
            "another server's cached profile must not be offered"
        )
        XCTAssertFalse(catalog.isServingFromCache)
        XCTAssertTrue(catalog.colors.isEmpty)
    }

    private static func colorDTO() throws -> PaletteColorDTO {
        let json = """
        {
          "id": 11,
          "name": "Cyan",
          "hex": "#00FFFF",
          "rgb": {"r": 0, "g": 255, "b": 255},
          "palette_id": 3,
          "palette_name": "Core",
          "sort_order": 2,
          "responses": {"red": {"brightness": 0.5}}
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PaletteColorDTO.self, from: Data(json.utf8))
    }
}
