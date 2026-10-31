import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Offline fallback behavior the generated-client migration must preserve
/// (issue #39): a successful colors fetch is cached per (server, profile),
/// the cache keeps serving exactly those colors with their original fetch
/// date once the server can no longer be reached, and previously fetched
/// profiles stay listed for the cached-profile picker fallback. The
/// offline-stale badge in the app renders from this `fetchedAt` date.
final class OfflineFallbackCacheTests: XCTestCase {
    private static let server = "http://example.com"
    private static let fetchDate = Date(timeIntervalSince1970: 1_700_000_000)

    private var cacheDirectory: URL!

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineFallbackCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        FallbackURLProtocol.handler = nil
        super.tearDown()
    }

    func testCachedFetchServesColorsWhenASubsequentRefetchFails() async throws {
        let cache = ProfileColorCache(directory: cacheDirectory)
        FallbackURLProtocol.handler = respondingOK(colorsJSON)
        let fetched = try await makeClient().fetchColors(printerProfileID: 7)
        try cache.store(CachedProfileColors(
            serverBaseUrl: Self.server,
            profileId: 7,
            profile: fetched.profile,
            colors: fetched.colors,
            fetchedAt: Self.fetchDate
        ))

        FallbackURLProtocol.handler = respondingWith(status: 503)
        await XCTAssertThrowsErrorAsync(try await makeClient().fetchColors(printerProfileID: 7)) { _ in }

        let cached = try XCTUnwrap(cache.entry(for: 7, serverBaseUrl: Self.server))
        XCTAssertEqual(cached.domainColors.map(\.id), fetched.colors.map(\.id))
        XCTAssertEqual(cached.fetchedAt, Self.fetchDate)
        XCTAssertTrue(cached.hasServableColors)
    }

    func testPreviouslyFetchedProfilesRemainListedForTheCachedPickerFallback() throws {
        let cache = ProfileColorCache(directory: cacheDirectory)
        try cache.store(try makeCachedEntry(profileID: 2))
        try cache.store(try makeCachedEntry(profileID: 1))

        let entries = cache.allEntries(serverBaseUrl: Self.server)

        XCTAssertEqual(entries.map(\.profileId), [1, 2])
        XCTAssertTrue(entries.allSatisfy(\.hasServableColors))
    }

    // MARK: Helpers

    private func makeClient() -> PaletteAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FallbackURLProtocol.self]
        return PaletteAPIClient(
            baseURL: URL(string: Self.server)!,
            session: URLSession(configuration: configuration)
        )
    }

    private func makeCachedEntry(profileID: Int) throws -> CachedProfileColors {
        let json = "{\"id\":\(profileID)0,\"name\":\"Color \(profileID)\",\"hex\":\"#112233\","
            + "\"rgb\":{\"r\":17,\"g\":34,\"b\":51},"
            + "\"responses\":{\"red\":{\"brightness\":0.5}}}"
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let color = try decoder.decode(PaletteColorDTO.self, from: Data(json.utf8))
        return CachedProfileColors(
            serverBaseUrl: Self.server,
            profileId: profileID,
            profile: PrinterProfileDTO(
                id: profileID, printerMakeModel: "Epson", paperType: "Matte", inkType: "Dye"
            ),
            colors: [color],
            fetchedAt: Self.fetchDate
        )
    }

    private func respondingOK(_ data: Data) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in (.init(statusCode: 200, url: request.url!), data) }
    }

    private func respondingWith(status: Int) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in (.init(statusCode: status, url: request.url!), Data()) }
    }
}

private let colorsJSON = """
{
  "printer_profile": {"id": 7, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"},
  "colors": [
    {"id": 11, "name": "Red 12", "hex": "#C64A35", "rgb": {"r": 198, "g": 74, "b": 53},
     "responses": {"red": {"brightness": 0.87}, "lps": {"brightness": 0.52}}},
    {"id": 12, "name": "Blue 3", "hex": "#354AC6", "rgb": {"r": 53, "g": 74, "b": 198},
     "responses": {"blue": {"brightness": 0.66}}}
  ]
}
""".data(using: .utf8)!

private final class FallbackURLProtocol: URLProtocol, @unchecked Sendable {
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
    convenience init(statusCode: Int, url: URL) {
        self.init(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
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
