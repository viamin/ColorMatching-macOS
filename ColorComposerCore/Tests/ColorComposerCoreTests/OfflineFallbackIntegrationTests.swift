import Foundation
import XCTest
@testable import ColorComposerCore

/// End-to-end glue between `PaletteAPIClient` and `ProfileColorCache` — the
/// behavior issue #39 says the generated-client migration must keep intact:
/// a successful fetch is cacheable to disk per server and profile, and the
/// cached entry can serve the app offline (offline-stale badge data
/// included), with the cached profile still available for the picker
/// fallback when the server is unreachable.
final class OfflineFallbackIntegrationTests: XCTestCase {
    private var cacheDirectory: URL!

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineFallbackIntegrationTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        WireMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testFetchedColorsRoundTripDiskCacheForOfflineStaleService() async throws {
        let server = "http://offline.example.com"
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let fetched = try await fetchColors(profileID: 7, server: server)

        let cache = ProfileColorCache(directory: cacheDirectory)
        try cache.store(CachedProfileColors(
            serverBaseUrl: server,
            profileId: 7,
            profile: fetched.profile,
            colors: fetched.colors,
            fetchedAt: fetchedAt
        ))
        // A fresh cache instance reads from disk, proving the offline path.
        let offline = try XCTUnwrap(
            ProfileColorCache(directory: cacheDirectory).entry(for: 7, serverBaseUrl: server),
            "cached fetch must be servable offline"
        )
        XCTAssertEqual(offline.colors, fetched.colors, "wire DTOs must survive the disk round-trip unmodified")
        XCTAssertEqual(offline.profile, fetched.profile, "cached profile fallback must be the envelope profile")
        XCTAssertEqual(offline.fetchedAt, fetchedAt, "fetch timestamp feeds the offline-stale badge")
        XCTAssertEqual(offline.domainColors.count, 2, "cached colors must convert for the solver")
        XCTAssertTrue(offline.hasServableColors)
    }

    func testCachedProfilesAppearInAllEntriesForOfflinePicker() async throws {
        let server = "http://unreachable.example.com"
        let cache = ProfileColorCache(directory: cacheDirectory)
        try await storeFetched(profileID: 2, server: server, cache: cache)
        try await storeFetched(profileID: 9, server: server, cache: cache)

        let entries = ProfileColorCache(directory: cacheDirectory).allEntries(serverBaseUrl: server)

        XCTAssertEqual(entries.map(\.profileId), [2, 9], "picker fallback lists cached profiles ordered by id")
        XCTAssertEqual(entries.first?.profile?.displayName, "Epson P900 · Matte · Dye")
        XCTAssertTrue(entries.allSatisfy(\.hasServableColors))
    }

    // MARK: - Fetch-through-mock helpers

    private func fetchColors(profileID: Int, server: String) async throws
        -> (colors: [PaletteColorDTO], profile: PrinterProfileDTO?)
    {
        WireMockURLProtocol.handler = { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsPayload(profileID: profileID))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WireMockURLProtocol.self]
        let client = PaletteAPIClient(
            baseURL: URL(string: server)!,
            session: URLSession(configuration: configuration)
        )
        return try await client.fetchColors(printerProfileID: profileID)
    }

    private func storeFetched(
        profileID: Int,
        server: String,
        cache: ProfileColorCache
    ) async throws {
        let fetched = try await fetchColors(profileID: profileID, server: server)
        try cache.store(CachedProfileColors(
            serverBaseUrl: server,
            profileId: profileID,
            profile: fetched.profile,
            colors: fetched.colors,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
    }

    /// Envelope payload whose `printer_profile` matches the requested id, so
    /// the cache's profile-id integrity check keeps the profile on read.
    private static func colorsPayload(profileID: Int) -> Data {
        """
        {
          "printer_profile": {"id": \(profileID), "printer_make_model": "Epson P900", "paper_type": "Matte", "ink_type": "Dye"},
          "colors": [
            {"id": 11, "name": "Red 12", "hex": "#C64A35", "rgb": {"r": 198, "g": 74, "b": 53},
             "responses": {"red": {"brightness": 0.87, "source": "measurement"}}},
            {"id": 12, "name": "Blue 3", "hex": "#3564C6", "rgb": {"r": 53, "g": 100, "b": 198},
             "responses": {"blue": {"brightness": 0.9, "source": "response", "apparent_brightness": 9}}}
          ]
        }
        """.data(using: .utf8)!
    }
}

private final class WireMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension HTTPURLResponse {
    convenience init(statusCode: Int, url: URL) {
        self.init(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }
}
