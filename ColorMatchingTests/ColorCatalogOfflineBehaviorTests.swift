import Foundation
import XCTest
@testable import ColorMatching
import ColorComposerCore

/// Regression baseline for issue #39's "preserve existing behavior" criterion:
/// per-server/profile color caching, offline-stale badging, and cached-profile
/// fallback must all survive the migration of `PaletteAPIClient` onto a
/// generated OpenAPI client. `ColorCatalog` (the integration point for the
/// client + `ProfileColorCache`) had no dedicated test coverage before this
/// file, so these tests pin today's behavior as a baseline the migration must
/// not change.
///
/// `PaletteAPIClient`'s default session is `URLSession.shared`, and
/// `ColorCatalog` does not expose a session override, so requests are
/// intercepted by globally registering `CatalogMockURLProtocol` — the
/// standard technique for stubbing `.shared`-backed network calls.
@MainActor
final class ColorCatalogOfflineBehaviorTests: XCTestCase {
    private let serverURL = URL(string: "https://catalog-tests.invalid")!
    private var cacheDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ColorCatalogOfflineBehaviorTests-\(UUID().uuidString)", isDirectory: true)
        URLProtocol.registerClass(CatalogMockURLProtocol.self)
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(CatalogMockURLProtocol.self)
        CatalogMockURLProtocol.handler = nil
        if let cacheDirectory {
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        try await super.tearDown()
    }

    private func makeCatalog() -> ColorCatalog {
        ColorCatalog(cache: ProfileColorCache(directory: cacheDirectory))
    }

    func testSuccessfulFetchPersistsPerServerProfileColorCacheToDisk() async throws {
        CatalogMockURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("printer_profiles") == true {
                return (200, Self.printerProfilesResponse())
            }
            return (200, Self.colorsResponse())
        }

        let catalog = makeCatalog()
        catalog.configure(baseURL: serverURL, token: nil)
        await catalog.refreshAll()

        XCTAssertFalse(catalog.isServingFromCache)
        XCTAssertEqual(catalog.colors.map(\.id), [42])

        let diskCache = ProfileColorCache(directory: cacheDirectory)
        let cached = diskCache.entry(for: 7, serverBaseUrl: serverURL.absoluteString)
        XCTAssertEqual(cached?.profileId, 7)
        XCTAssertEqual(cached?.colors.map(\.id), [42])
    }

    func testUnreachableServerFallsBackToCachedProfilesAndColorsBadgedAsStale() async throws {
        let diskCache = ProfileColorCache(directory: cacheDirectory)
        let fetchedAt = Date(timeIntervalSinceNow: -3600)
        try diskCache.store(CachedProfileColors(
            serverBaseUrl: serverURL.absoluteString,
            profileId: 7,
            profile: PrinterProfileDTO(id: 7, printerMakeModel: "Cached Printer", paperType: "Matte", inkType: "Pigment"),
            colors: [try Self.samplePaletteColorDTO()],
            fetchedAt: fetchedAt
        ))

        CatalogMockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }

        let catalog = makeCatalog()
        catalog.configure(baseURL: serverURL, token: nil)
        await catalog.refreshAll()

        // Cached profile fallback: the picker is populated from the cache with
        // no server round-trip possible, and the cached profile is selected.
        XCTAssertEqual(catalog.printerProfiles.map(\.id), [7])
        XCTAssertEqual(catalog.selectedPrinterProfileID, 7)

        // Offline-stale badge: the cached colors are served and flagged.
        XCTAssertTrue(catalog.isServingFromCache)
        XCTAssertEqual(catalog.colors.map(\.id), [42])
        XCTAssertEqual(catalog.lastRefresh, fetchedAt)
        XCTAssertTrue(
            catalog.connectionMessage?.contains("showing cached colors from") == true,
            "expected an offline-stale message, got \(String(describing: catalog.connectionMessage))"
        )
    }

    func testUnreachableServerWithNoCacheReportsFailureWithoutStaleBadge() async throws {
        CatalogMockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }

        let catalog = makeCatalog()
        catalog.configure(baseURL: serverURL, token: nil)
        await catalog.refreshAll()

        XCTAssertTrue(catalog.printerProfiles.isEmpty)
        XCTAssertNil(catalog.selectedPrinterProfileID)
        XCTAssertFalse(catalog.isServingFromCache)
        XCTAssertTrue(catalog.colors.isEmpty)
        XCTAssertEqual(catalog.connectionMessage, "Could not reach the server.")
    }

    // MARK: - Fixtures

    // Marked `nonisolated`: these are called from `CatalogMockURLProtocol`'s
    // `@Sendable` handler closures, which run outside the MainActor isolation
    // this test class otherwise has (required because `ColorCatalog` itself
    // is `@MainActor`-isolated).
    private static nonisolated func printerProfilesResponse() -> Data {
        """
        {
          "printer_profiles": [
            { "id": 7, "printer_make_model": "Test Printer", "paper_type": "Matte", "ink_type": "Pigment" }
          ]
        }
        """.data(using: .utf8)!
    }

    private static nonisolated func colorsResponse() -> Data {
        """
        {
          "colors": [
            {
              "id": 42,
              "name": "Red A",
              "hex": "#ff0000",
              "rgb": { "r": 255, "g": 0, "b": 0 },
              "palette_id": 1,
              "palette_name": "Basics",
              "sort_order": 1,
              "responses": {
                "red": { "brightness": 0.5, "source": "measurement", "raw_value": 10.0, "raw_unit": "cd/m2" }
              }
            }
          ],
          "printer_profile": { "id": 7, "printer_make_model": "Test Printer", "paper_type": "Matte", "ink_type": "Pigment" }
        }
        """.data(using: .utf8)!
    }

    private static func samplePaletteColorDTO() throws -> PaletteColorDTO {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PaletteColorDTO.self, from: Data("""
        {
          "id": 42,
          "name": "Cached Red A",
          "hex": "#ff0000",
          "rgb": { "r": 255, "g": 0, "b": 0 },
          "palette_id": 1,
          "palette_name": "Basics",
          "sort_order": 1,
          "responses": {
            "red": { "brightness": 0.5, "source": "measurement", "raw_value": 10.0, "raw_unit": "cd/m2" }
          }
        }
        """.utf8))
    }
}

/// Globally-registered `URLProtocol` stub for `URLSession.shared`, scoped to
/// requests addressed to the fixed test host so it never intercepts anything
/// else running in the same process.
private final class CatalogMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "catalog-tests.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (statusCode, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
