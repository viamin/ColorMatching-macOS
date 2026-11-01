import Foundation
import XCTest
@testable import ColorComposerCore

/// Guards the fetch → disk-cache → offline-fallback pipeline across the
/// generated OpenAPI-client migration (#39).
///
/// Whatever transport ends up inside `PaletteAPIClient`, the contract the app
/// depends on is: the wire DTOs `fetchColors` returns are exactly the DTOs
/// `ColorCatalog.applyFetched` stores in `ProfileColorCache`, and exactly what
/// an offline read later serves (same colors, same `fetchedAt` staleness
/// marker that drives the offline-stale badge, same domain conversion the
/// solver consumes). This test wires those three pieces together against a
/// mocked wire response, so a migration that changes any hop fails here.
final class PaletteFetchCachingTests: XCTestCase {
    private var cacheDirectory: URL!

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaletteFetchCachingTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testFetchedColorsRoundTripThroughDiskCacheForOfflineServing() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.wireColorsResponse())
        }
        let fetchedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let server = "http://example.com"

        // Fetch (the migration surface) — the DTOs come off the wire.
        let (dtos, profile) = try await client.fetchColors(printerProfileID: 7)

        // Cache, the way ColorCatalog.applyFetched stores a successful fetch.
        let cache = ProfileColorCache(directory: cacheDirectory)
        try cache.store(CachedProfileColors(
            serverBaseUrl: server,
            profileId: 7,
            profile: profile,
            colors: dtos,
            fetchedAt: fetchedAt
        ))

        // Serve offline with a fresh cache instance, as a cold launch would.
        let offline = ProfileColorCache(directory: cacheDirectory)
        let entry = try XCTUnwrap(
            offline.entry(for: 7, serverBaseUrl: server),
            "The cached fetch must be readable when the server is unreachable"
        )

        XCTAssertEqual(entry.colors, dtos, "Offline-served DTOs must be byte-identical to the fetched DTOs")
        XCTAssertEqual(entry.profile, profile)
        XCTAssertEqual(entry.fetchedAt, fetchedAt, "The staleness marker behind the offline-stale badge must survive")
        XCTAssertEqual(entry.domainColors, dtos.map { $0.toDomain()! },
            "Solver-ready domain colors must be identical whether fetched or served from cache")
        XCTAssertTrue(entry.hasServableColors)

        // And the served palette actually composes: the offline fallback keeps
        // the Generate flow working end to end.
        let result = try CompositionSolver().solve(
            palette: entry.domainColors,
            sourceGrids: [.red: BrightnessGrid(width: 1, height: 1, fill: 0.9)],
            weights: ChannelWeights(red: 1.0)
        )
        XCTAssertEqual(result.colorIndex(x: 0, y: 0), 1,
            "The brighter-measured color must win for a 0.9 red target")
    }

    // MARK: - Fixtures

    private func makeClient(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return PaletteAPIClient(
            baseURL: URL(string: "http://example.com")!,
            session: URLSession(configuration: configuration)
        )
    }

    /// Two fully-measured red colors: brightness 0.25 and 0.75.
    private static func wireColorsResponse() -> Data {
        """
        {
          "printer_profile": {"id": 7, "printer_make_model": "Epson SC700", "paper_type": "Matte", "ink_type": "Pigment"},
          "colors": [
            {"id": 1, "name": "Dim", "hex": "#404040", "rgb": {"r": 64, "g": 64, "b": 64},
             "responses": {"red": {"brightness": 0.25}}},
            {"id": 2, "name": "Bright", "hex": "#C0C0C0", "rgb": {"r": 192, "g": 192, "b": 192},
             "responses": {"red": {"brightness": 0.75}}}
          ]
        }
        """.data(using: .utf8)!
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
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
