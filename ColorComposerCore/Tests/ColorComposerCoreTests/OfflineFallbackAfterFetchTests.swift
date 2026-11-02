import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Offline fallback across the real fetch → disk-cache → re-read path.
///
/// These are the "disk cache + offline fallback behavior verified unchanged"
/// pins for the generated-OpenAPI-client migration (issue #39): the DTOs a
/// live `PaletteAPIClient` fetch decodes are exactly what gets cached per
/// (server, profile) and exactly what is served back when the server cannot
/// be reached, so the offline-stale badges and the cached-profile picker
/// keep working after the client is rebuilt on the generated code.
final class OfflineFallbackAfterFetchTests: XCTestCase {
    private var cacheDirectory: URL!

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineFallbackAfterFetchTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        OfflineFallbackMockURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: cacheDirectory)
        super.tearDown()
    }

    private func makeClient(
        baseURL: String,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        OfflineFallbackMockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineFallbackMockURLProtocol.self]
        return PaletteAPIClient(
            baseURL: URL(string: baseURL)!,
            token: nil,
            session: URLSession(configuration: configuration)
        )
    }

    private func ok(_ body: Data) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
    }

    private func colorsBody(profileID: Int, colorID: Int, brightness: Double) -> Data {
        let hex = String(format: "#%06x", UInt32(colorID * 37 % 0xFFFFFF))
        return """
        {
          "printer_profile": {"id": \(profileID), "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"},
          "colors": [
            {
              "id": \(colorID), "name": "Swatch \(colorID)", "hex": "\(hex)",
              "rgb": {"r": 17, "g": 34, "b": 51},
              "responses": {"red": {"brightness": \(brightness)}, "lps": {"brightness": \(brightness / 2)}}
            }
          ]
        }
        """.data(using: .utf8)!
    }

    /// Fetch from a live (mocked) server, cache the result the way the app
    /// does, then verify the offline read serves the identical colors and
    /// that they convert to the same solver palette.
    func testFetchedColorsSurviveOfflineRoundTripIdentically() async throws {
        let cache = ProfileColorCache(directory: cacheDirectory)
        let server = "http://offline.example.com"
        let client = makeClient(baseURL: server, handler: ok(colorsBody(profileID: 3, colorID: 42, brightness: 0.75)))
        let fetchedAt = Date(timeIntervalSince1970: 1_750_000_000)

        let fetched = try await client.fetchColors(printerProfileID: 3)
        try cache.store(CachedProfileColors(
            serverBaseUrl: server,
            profileId: 3,
            profile: fetched.profile,
            colors: fetched.colors,
            fetchedAt: fetchedAt
        ))

        // The server is now unreachable — no client is used; the cache alone
        // must serve the fetch byte-for-byte.
        let cached = try XCTUnwrap(cache.entry(for: 3, serverBaseUrl: server))
        XCTAssertEqual(cached.colors, fetched.colors)
        XCTAssertEqual(cached.profile, fetched.profile)
        XCTAssertEqual(cached.fetchedAt, fetchedAt)
        XCTAssertTrue(cached.hasServableColors)

        let fetchedDomain = fetched.colors.compactMap { $0.toDomain() }
        XCTAssertEqual(cached.domainColors, fetchedDomain)
        XCTAssertEqual(cached.domainColors.first?.brightness(for: .red), 0.75)
        XCTAssertEqual(cached.domainColors.first?.brightness(for: .lps), 0.375)
    }

    /// Offline cold start: every cached profile for the server is offered to
    /// the picker (sorted by profile id), each still servable.
    func testCachedProfilesServeOfflinePickerFallback() async throws {
        let cache = ProfileColorCache(directory: cacheDirectory)
        let server = "http://picker.example.com"
        let fetchedAt = Date(timeIntervalSince1970: 1_750_000_100)

        for profileID in [9, 4] {
            let client = makeClient(baseURL: server, handler: ok(colorsBody(profileID: profileID, colorID: profileID, brightness: 0.5)))
            let fetched = try await client.fetchColors(printerProfileID: profileID)
            try cache.store(CachedProfileColors(
                serverBaseUrl: server,
                profileId: profileID,
                profile: fetched.profile,
                colors: fetched.colors,
                fetchedAt: fetchedAt
            ))
        }

        let entries = cache.allEntries(serverBaseUrl: server)
        XCTAssertEqual(entries.map(\.profileId), [4, 9], "cached profiles are offered sorted by profile id")
        XCTAssertTrue(entries.allSatisfy(\.hasServableColors))
    }

    /// Profile ids are unique only per server: the same profile id fetched
    /// from two servers must never be served across servers, even though
    /// both clients and caches are otherwise identical.
    func testSameProfileIDFromTwoServersStaysNamespaced() async throws {
        let cache = ProfileColorCache(directory: cacheDirectory)
        let serverA = "http://a.example.com"
        let serverB = "http://b.example.com"
        let fetchedAt = Date(timeIntervalSince1970: 1_750_000_200)

        let clientA = makeClient(baseURL: serverA, handler: ok(colorsBody(profileID: 5, colorID: 501, brightness: 0.1)))
        let fetchedA = try await clientA.fetchColors(printerProfileID: 5)
        try cache.store(CachedProfileColors(
            serverBaseUrl: serverA, profileId: 5,
            profile: fetchedA.profile, colors: fetchedA.colors, fetchedAt: fetchedAt
        ))

        let clientB = makeClient(baseURL: serverB, handler: ok(colorsBody(profileID: 5, colorID: 502, brightness: 0.9)))
        let fetchedB = try await clientB.fetchColors(printerProfileID: 5)
        try cache.store(CachedProfileColors(
            serverBaseUrl: serverB, profileId: 5,
            profile: fetchedB.profile, colors: fetchedB.colors, fetchedAt: fetchedAt
        ))

        let offlineA = try XCTUnwrap(cache.entry(for: 5, serverBaseUrl: serverA))
        let offlineB = try XCTUnwrap(cache.entry(for: 5, serverBaseUrl: serverB))
        XCTAssertEqual(offlineA.colors, fetchedA.colors)
        XCTAssertEqual(offlineB.colors, fetchedB.colors)
        XCTAssertEqual(offlineA.colors.first?.id, 501)
        XCTAssertEqual(offlineB.colors.first?.id, 502)
    }
}

private final class OfflineFallbackMockURLProtocol: URLProtocol, @unchecked Sendable {
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
