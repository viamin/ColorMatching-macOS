import Foundation
import XCTest
import ColorComposerCore
@testable import ColorMatching

/// Pins the offline behavior of `ColorCatalog` (issue #39 acceptance: the
/// generated-client migration must preserve per-server/profile color caching,
/// offline-stale badges, and cached profile fallback).
///
/// `ColorCatalog` builds its `PaletteAPIClient` on `URLSession.shared`, so
/// these tests intercept traffic by registering `OfflineStubURLProtocol`
/// globally — the documented injection point for the shared session — and
/// point the catalog at a seeded `ProfileColorCache` in a temp directory.
/// They run on macOS with the app host (see the ColorMatching scheme).
final class ColorCatalogOfflineFallbackTests: XCTestCase {
    private var cacheDirectory: URL!

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ColorCatalogOfflineFallbackTests-\(UUID().uuidString)", isDirectory: true)
        _ = URLProtocol.registerClass(OfflineStubURLProtocol.self)
    }

    override func tearDown() {
        OfflineStubURLProtocol.handler = nil
        URLProtocol.unregisterClass(OfflineStubURLProtocol.self)
        try? FileManager.default.removeItem(at: cacheDirectory)
        super.tearDown()
    }

    // MARK: - Offline-stale badge on colors

    @MainActor
    func testTransportFailureServesCachedColorsWithStaleBadge() async throws {
        let catalog = try makeCatalog(seededProfileIDs: [7])
        OfflineStubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        catalog.selectedPrinterProfileID = 7

        await waitUntil { catalog.isServingFromCache }
        XCTAssertFalse(catalog.colors.isEmpty, "cached fetch should serve its colors")
        XCTAssertEqual(catalog.loadedColorsProfileID, 7)
        XCTAssertTrue(
            catalog.connectionMessage?.contains("showing cached colors") == true,
            "message should badge the colors as cached, got: \(String(describing: catalog.connectionMessage))"
        )
    }

    @MainActor
    func testCachedColorsAreNotServedAcrossServers() async throws {
        let catalog = try makeCatalog(seededProfileIDs: [7])
        OfflineStubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        // Seed belongs to example.com; the catalog is configured for another
        // server, so the offline fallback must miss rather than cross servers.
        catalog.configure(baseURL: URL(string: "http://elsewhere.example")!, token: nil)
        catalog.selectedPrinterProfileID = 7

        await waitUntil { catalog.connectionMessage != nil }
        XCTAssertFalse(catalog.isServingFromCache)
        XCTAssertTrue(catalog.colors.isEmpty)
    }

    // MARK: - Cached profile fallback (offline cold start)

    @MainActor
    func testOfflineColdStartOffersCachedProfilesAndServesTheirColors() async throws {
        let catalog = try makeCatalog(seededProfileIDs: [3, 7])
        OfflineStubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        await catalog.refreshAll()

        XCTAssertEqual(catalog.printerProfiles.map(\.id), [3, 7], "cached profiles should populate the picker")
        XCTAssertEqual(catalog.selectedPrinterProfileID, 3, "the first cached profile should be selected")
        XCTAssertTrue(catalog.isServingFromCache, "the selected profile's colors should come from the cache")
        XCTAssertFalse(catalog.colors.isEmpty)
        XCTAssertTrue(catalog.connectionMessage?.contains("showing cached colors") == true)
    }

    // MARK: - Non-transport failures never claim offline

    @MainActor
    func testUnauthorizedFailureDoesNotServeCachedColors() async throws {
        let catalog = try makeCatalog(seededProfileIDs: [7])
        OfflineStubURLProtocol.handler = { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        catalog.selectedPrinterProfileID = 7

        await waitUntil { catalog.connectionMessage != nil }
        XCTAssertFalse(catalog.isServingFromCache, "a 401 must not masquerade as offline")
        XCTAssertTrue(catalog.colors.isEmpty)
        XCTAssertTrue(
            catalog.connectionMessage?.contains("token was rejected") == true,
            "the failure should be reported plainly, got: \(String(describing: catalog.connectionMessage))"
        )
    }

    // MARK: - Live fetch clears the stale badge

    @MainActor
    func testLiveFetchAfterOfflineFallbackClearsStaleBadge() async throws {
        let catalog = try makeCatalog(seededProfileIDs: [7])
        let responses = StubResponses()
        OfflineStubURLProtocol.handler = { request in try responses.next(request) }

        catalog.selectedPrinterProfileID = 7
        await waitUntil { catalog.isServingFromCache }

        responses.switchToLive()
        await catalog.refreshAll()

        XCTAssertFalse(catalog.isServingFromCache, "a live fetch must clear the stale badge")
        XCTAssertEqual(catalog.colors.count, 1)
        XCTAssertEqual(catalog.loadedColorsProfileID, 7)
        XCTAssertEqual(catalog.connectionMessage, "Loaded 1 color(s) for this profile.")
    }

    // MARK: - Fixtures and plumbing

    private static let server = "http://example.com"

    private func makeCatalog(seededProfileIDs profileIDs: [Int]) throws -> ColorCatalog {
        let cache = ProfileColorCache(directory: cacheDirectory)
        for profileID in profileIDs {
            try cache.store(CachedProfileColors(
                serverBaseUrl: Self.server,
                profileId: profileID,
                profile: PrinterProfileDTO(
                    id: profileID, printerMakeModel: "Epson", paperType: "Matte", inkType: "Dye"
                ),
                colors: try decodeColors(#"{"id": 71, "hex": "#00AAFF", "responses": {"white": {"brightness": 0.8}, "lps": {"brightness": 0.3}}}}"#),
                fetchedAt: Date(timeIntervalSince1970: 1_767_000_000)
            ))
        }
        let catalog = ColorCatalog(cache: cache)
        catalog.configure(baseURL: URL(string: Self.server)!, token: nil)
        return catalog
    }

    /// `PaletteColorDTO`'s memberwise initializer is not public, so wire
    /// payloads are decoded — exactly the bytes the server sends.
    private func decodeColors(_ json: String) throws -> [PaletteColorDTO] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([PaletteColorDTO].self, from: Data(json.utf8))
    }

    /// Polls `condition` by yielding the main actor until it holds. Catalog
    /// fetches run in detached main-actor tasks, so no sleeping is needed —
    /// the mock transport resolves synchronously in-process.
    @MainActor
    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<50_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("condition not met before yielding budget ran out", file: file, line: line)
    }
}

// MARK: - Transport stub

private final class OfflineStubURLProtocol: URLProtocol, @unchecked Sendable {
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

/// Switches every intercepted request between "offline" and a live server
/// serving profile 7 with one color.
private final class StubResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var live = false

    func switchToLive() {
        lock.lock()
        live = true
        lock.unlock()
    }

    func next(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        lock.lock()
        let isLive = live
        lock.unlock()
        guard isLive else { throw URLError(.notConnectedToInternet) }

        if request.url?.path.hasSuffix("printer_profiles") == true {
            return (
                .init(statusCode: 200, url: request.url!),
                Data(#"{"printer_profiles": [{"id": 7, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"}]}"#.utf8)
            )
        }
        return (
            .init(statusCode: 200, url: request.url!),
            Data(#"{"colors": [{"id": 71, "hex": "#00AAFF", "responses": {"white": {"brightness": 0.5}}}], "printer_profile": {"id": 7, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"}}"#.utf8)
        )
    }
}
