import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Behavior-preservation guards for the issue #39 generated-client migration.
///
/// `PaletteAPIClient` is being migrated onto the OpenAPI-generated client
/// (viamin/color_matching#110). These tests pin the observable contract the
/// migration must keep: the `/api/v1` wire shapes, bearer-token handling,
/// distinct error classification, and the offline-stale disk-cache fallback
/// flow (cached colors served with their fetch date when the server is
/// unreachable, cached profiles offered when it can't be reached at all).
final class PaletteAPIClientBehaviorTests: XCTestCase {
    private var cacheDirectory: URL!

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaletteAPIClientBehaviorTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        ScriptedURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Wire contract

    func testFetchPrinterProfilesHitsAPIV1AndDecodesEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesEnvelope())
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.map(\.id), [1, 2])
        XCTAssertEqual(profiles.first?.printerMakeModel, "Epson XP-8600")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
        XCTAssertEqual(profiles.last?.inkType, "Pigment")
    }

    func testFetchColorsSendsProfileQueryAndDecodesEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/colors")
            XCTAssertEqual(
                request.url?.query?.split(separator: "&").map(String.init).sorted(),
                ["printer_profile_id=3"]
            )
            return (.init(statusCode: 200, url: request.url!), Self.colorsEnvelope())
        }

        let fetched = try await client.fetchColors(printerProfileID: 3)

        XCTAssertEqual(fetched.colors.map(\.id), [123])
        XCTAssertEqual(fetched.colors.first?.name, "Red 12")
        XCTAssertEqual(fetched.colors.first?.hex, "#C64A35")
        XCTAssertEqual(fetched.colors.first?.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(fetched.colors.first?.responses["lps"]?.apparentBrightness, 5)
        XCTAssertEqual(fetched.profile?.id, 3)
    }

    func testFetchColorsWithoutProfileMetadataStillDecodes() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsEnvelopeWithoutProfile())
        }

        let fetched = try await client.fetchColors(printerProfileID: 3)

        XCTAssertEqual(fetched.colors.map(\.id), [9])
        XCTAssertNil(fetched.profile)
    }

    // MARK: - Error classification

    func testFetchColorsSurfacesUnauthorizedDistinctly() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 3)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testMalformedBodyBecomesMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testNon2xxBecomesBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testTestConnectionSucceedsOn2xx() async throws {
        let client = makeClient { request in
            (.init(statusCode: 204, url: request.url!), Data())
        }

        await XCTAssertNoThrowAsync(try await client.testConnection())
    }

    // MARK: - Offline-stale fallback flow

    /// The full offline flow: fetch → cache to disk → server unreachable →
    /// the cached colors (byte-identical DTOs plus the fetch date that drives
    /// the offline-stale badge) must be servable from the cache.
    func testOfflineFailureServesCachedColorsWithStalenessMarker() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsEnvelope())
        }
        let cache = ProfileColorCache(directory: cacheDirectory)
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let fetched = try await client.fetchColors(printerProfileID: 3)
        try cache.store(CachedProfileColors(
            serverBaseUrl: client.baseURL.absoluteString,
            profileId: 3,
            profile: fetched.profile,
            colors: fetched.colors,
            fetchedAt: fetchedAt
        ))

        ScriptedURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 3)) { _ in }

        let entry = try XCTUnwrap(cache.entry(for: 3, serverBaseUrl: "http://example.com"))
        XCTAssertEqual(entry.colors, fetched.colors, "Offline fallback must serve the exact cached DTOs")
        XCTAssertEqual(entry.profile, fetched.profile, "Cached profile metadata must survive the disk round-trip")
        XCTAssertEqual(entry.fetchedAt, fetchedAt, "The fetch date drives the offline-stale badge and must be preserved")
        XCTAssertTrue(entry.hasServableColors)
        XCTAssertEqual(entry.domainColors.map(\.id), [123])
    }

    /// When the server can't be reached at all, the profile picker falls back
    /// to every cached profile for that server (`allEntries`), keyed by
    /// profile id in order.
    func testCachedProfileFallbackListsAllEntriesForServer() async throws {
        let cache = ProfileColorCache(directory: cacheDirectory)
        try cache.store(CachedProfileColors(
            serverBaseUrl: "http://example.com",
            profileId: 3,
            profile: PrinterProfileDTO(id: 3, printerMakeModel: "Epson", paperType: "Matte", inkType: "Dye"),
            colors: [Self.minimalColorDTO()],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try cache.store(CachedProfileColors(
            serverBaseUrl: "http://example.com",
            profileId: 1,
            profile: PrinterProfileDTO(id: 1, printerMakeModel: "Canon", paperType: "Glossy", inkType: "Pigment"),
            colors: [Self.minimalColorDTO()],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_001)
        ))

        XCTAssertEqual(cache.allEntries(serverBaseUrl: "http://example.com").map(\.profileId), [1, 3])
    }

    // MARK: - Fixtures

    private func makeClient(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        ScriptedURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(baseURL: URL(string: "http://example.com")!, session: session)
    }

    private static func printerProfilesEnvelope() -> Data {
        """
        {
          "printer_profiles": [
            { "id": 1, "printer_make_model": "Epson XP-8600", "paper_type": "Matte", "ink_type": "Dye" },
            { "id": 2, "printer_make_model": "Canon Pro-1000", "paper_type": "Glossy", "ink_type": "Pigment" }
          ]
        }
        """.data(using: .utf8)!
    }

    private static func colorsEnvelope() -> Data {
        """
        {
          "printer_profile": {
            "id": 3, "printer_make_model": "Epson XP-8600", "paper_type": "Matte", "ink_type": "Dye"
          },
          "colors": [
            {
              "id": 123, "name": "Red 12", "hex": "#C64A35",
              "rgb": { "r": 198, "g": 74, "b": 53 },
              "palette_id": 5, "palette_name": "Default", "sort_order": 12,
              "responses": {
                "red": { "brightness": 0.87, "source": "measurement" },
                "lps": { "brightness": 0.52, "source": "response", "apparent_brightness": 5 }
              }
            }
          ]
        }
        """.data(using: .utf8)!
    }

    private static func colorsEnvelopeWithoutProfile() -> Data {
        """
        { "colors": [ { "id": 9, "hex": "#112233", "rgb": { "r": 17, "g": 34, "b": 51 }, "responses": {} } ] }
        """.data(using: .utf8)!
    }

    private static func minimalColorDTO() -> PaletteColorDTO {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let json = #"{"id":1,"name":"Color 1","hex":"#112233","rgb":{"r":17,"g":34,"b":51},"responses":{"red":{"brightness":0.5}}}"#
        return try! decoder.decode(PaletteColorDTO.self, from: Data(json.utf8))
    }
}

private final class ScriptedURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
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
    convenience init(statusCode: Int, url: URL?) {
        self.init(url: url ?? URL(string: "http://example.com")!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ assertions: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        assertions(error)
    }
}

private func XCTAssertNoThrowAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
    } catch {
        XCTFail("Expected no error, got \(error)", file: file, line: line)
    }
}
