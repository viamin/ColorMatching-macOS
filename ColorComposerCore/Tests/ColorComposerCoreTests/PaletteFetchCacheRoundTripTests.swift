import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// The offline fallback path the OpenAPI-client migration must not disturb
/// (issue #39): a live fetch's wire DTOs go into the per-server disk cache
/// verbatim, survive the round trip, and keep the fetch date that drives the
/// offline-stale badge and the cached-profile picker fallback.
final class PaletteFetchCacheRoundTripTests: XCTestCase {
    private static let serverBaseURL = "http://example.com"

    private static let colorsBody = """
    {
      "printer_profile": {
        "id": 7, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"
      },
      "colors": [
        {
          "id": 123, "name": "Red 12", "hex": "#C64A35",
          "rgb": {"r": 198, "g": 74, "b": 53},
          "responses": {"red": {"brightness": 0.87}, "lps": {"brightness": 0.52}}
        },
        {
          "id": 124, "name": "Teal 3", "hex": "#35C6B4",
          "rgb": {"r": 53, "g": 198, "b": 180},
          "responses": {"green": {"brightness": 0.61}}
        }
      ]
    }
    """.data(using: .utf8)!

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaletteFetchCacheRoundTripTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        PaletteAPITestSupportURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testFetchedColorsRoundTripThroughTheDiskCache() async throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let fetched = try await fetchSampleColors()
        let cache = ProfileColorCache(directory: directory)
        let entry = CachedProfileColors(
            serverBaseUrl: Self.serverBaseURL,
            profileId: 7,
            profile: fetched.profile,
            colors: fetched.colors,
            fetchedAt: fetchedAt
        )

        try cache.store(entry)

        let readBack = try XCTUnwrap(cache.entry(for: 7, serverBaseUrl: Self.serverBaseURL))
        XCTAssertEqual(readBack, entry)
        XCTAssertEqual(readBack.fetchedAt, fetchedAt)
        XCTAssertEqual(readBack.profile?.id, 7)
        XCTAssertEqual(readBack.domainColors.map(\.id), [123, 124])
        XCTAssertEqual(try XCTUnwrap(readBack.domainColors.first).brightness(for: .lps), 0.52)
        XCTAssertEqual(try XCTUnwrap(readBack.domainColors.last).brightness(for: .green), 0.61)
    }

    /// The cached-profile fallback enumerates what survives on disk when the
    /// server cannot be reached at all, so a round-tripped fetch must show up
    /// there too.
    func testRoundTrippedFetchIsListedAmongCachedProfiles() async throws {
        let fetched = try await fetchSampleColors()
        let cache = ProfileColorCache(directory: directory)
        try cache.store(CachedProfileColors(
            serverBaseUrl: Self.serverBaseURL,
            profileId: 7,
            profile: fetched.profile,
            colors: fetched.colors,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        XCTAssertEqual(cache.allEntries(serverBaseUrl: Self.serverBaseURL).map(\.profileId), [7])
    }

    private func fetchSampleColors() async throws -> (colors: [PaletteColorDTO], profile: PrinterProfileDTO?) {
        PaletteAPITestSupportURLProtocol.handler = { request in
            (PaletteAPITestSupportURLProtocol.response(statusCode: 200, url: request.url!), Self.colorsBody)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PaletteAPITestSupportURLProtocol.self]
        let client = PaletteAPIClient(
            baseURL: URL(string: Self.serverBaseURL)!,
            session: URLSession(configuration: configuration)
        )
        return try await client.fetchColors(printerProfileID: 7)
    }
}
