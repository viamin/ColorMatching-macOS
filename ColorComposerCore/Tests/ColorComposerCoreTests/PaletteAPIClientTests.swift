import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

final class PaletteAPIClientTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.handler = nil
    }

    func testFetchPrinterProfilesThrowsUnauthorizedWithoutRetryHandler() async {
        let client = makeClient { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer stale-token")
            return (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testFetchPrinterProfilesUsesTrimmedBearerToken() async throws {
        let lock = NSLock()
        var requests: [String?] = []
        let client = makeClient { request in
            lock.lock()
            requests.append(request.value(forHTTPHeaderField: "Authorization"))
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), printerProfilesResponse())
        }

        _ = try await client.fetchPrinterProfiles()

        XCTAssertEqual(requests, ["Bearer stale-token"])
    }

    /// The OpenAPI document describes `GET /api/v1/printer_profiles`; the
    /// generated client must keep calling exactly that path.
    func testFetchPrinterProfilesRequestsTheDocumentedPath() async throws {
        let lock = NSLock()
        var requestedPaths: [String] = []
        let client = makeClient { request in
            lock.lock()
            requestedPaths.append(request.url?.path ?? "")
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), printerProfilesResponse())
        }

        _ = try await client.fetchPrinterProfiles()

        XCTAssertEqual(requestedPaths, ["/api/v1/printer_profiles"])
    }

    /// `GET /api/v1/colors` takes the profile id as the documented
    /// `printer_profile_id` query parameter.
    func testFetchColorsRequestsTheDocumentedPathAndParameter() async throws {
        let lock = NSLock()
        var requestedURLs: [URL] = []
        let client = makeClient { request in
            lock.lock()
            requestedURLs.append(request.url!)
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), colorsResponse())
        }

        _ = try await client.fetchColors(printerProfileID: 42)

        XCTAssertEqual(requestedURLs.count, 1)
        let url = try XCTUnwrap(requestedURLs.first)
        XCTAssertEqual(url.path, "/api/v1/colors")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.map(\.name), ["printer_profile_id"])
        XCTAssertEqual(items.first?.value, "42")
    }

    /// The palette the client fetched must stay servable from the disk cache
    /// once the server is unreachable — the offline-stale path the app relies
    /// on when a server goes away.
    func testFetchedColorsStayServableFromTheDiskCacheWhenTheServerIsUnreachable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaletteAPIClientTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ProfileColorCache(directory: directory)
        let serverBaseUrl = "http://example.com"

        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), colorsResponse())
        }
        let fetched = try await client.fetchColors(printerProfileID: 7)
        try cache.store(CachedProfileColors(
            serverBaseUrl: serverBaseUrl,
            profileId: 7,
            profile: fetched.profile,
            colors: fetched.colors,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        let offlineClient = makeClient { request in throw URLError(.notConnectedToInternet) }
        await XCTAssertThrowsErrorAsync(try await offlineClient.fetchColors(printerProfileID: 7)) { _ in }

        let cached = try XCTUnwrap(cache.entry(for: 7, serverBaseUrl: serverBaseUrl))
        XCTAssertTrue(cached.hasServableColors)
        XCTAssertEqual(cached.domainColors.map(\.id), [1])
        XCTAssertEqual(cached.profile?.printerMakeModel, "Example Printer")
    }

    private func makeClient(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(baseURL: URL(string: "http://example.com")!, token: "  stale-token  ", session: session)
    }

    private func printerProfilesResponse() -> Data {
        """
        {
          "printer_profiles": [
            {
              "id": 1,
              "printer_make_model": "Example Printer",
              "paper_type": "Matte",
              "ink_type": "Pigment"
            }
          ]
        }
        """.data(using: .utf8)!
    }

    /// A `GET /api/v1/colors` payload in the shape the OpenAPI document
    /// describes: the profile the colors belong to, plus the colors with
    /// their measured responses.
    private func colorsResponse() -> Data {
        """
        {
          "printer_profile": {
            "id": 7,
            "printer_make_model": "Example Printer",
            "paper_type": "Matte",
            "ink_type": "Pigment"
          },
          "colors": [
            {
              "id": 1,
              "name": "Color 1",
              "hex": "#112233",
              "rgb": {"r": 17, "g": 34, "b": 51},
              "palette_id": 5,
              "palette_name": "Default",
              "sort_order": 12,
              "responses": {
                "red": {"brightness": 0.5}
              }
            }
          ]
        }
        """.data(using: .utf8)!
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
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
