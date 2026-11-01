import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Behavioral contract of `PaletteAPIClient`.
///
/// These tests are the migration net for the generated OpenAPI client
/// (issue #39): whichever transport ends up behind `fetchPrinterProfiles`,
/// `fetchColors`, and `testConnection`, these observable behaviors — paths,
/// query parameters, headers, error mapping, and envelope decoding — must
/// survive unchanged so the disk-cache/offline-stale behavior built on top
/// keeps working.
final class PaletteAPIClientTests: XCTestCase {
    private var requests: RecordedRequests!

    override func setUp() {
        super.setUp()
        requests = RecordedRequests()
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testFetchPrinterProfilesThrowsUnauthorizedWithoutRetryHandler() async {
        let client = makeClient(status: 401, body: Data()) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer stale-token")
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testFetchPrinterProfilesUsesTrimmedBearerToken() async throws {
        let client = makeClient(status: 200, body: printerProfilesResponse())

        _ = try await client.fetchPrinterProfiles()

        XCTAssertEqual(requests.headers(named: "Authorization"), ["Bearer stale-token"])
        XCTAssertEqual(requests.paths, ["/api/v1/printer_profiles"])
    }

    func testFetchPrinterProfilesDecodesEnvelope() async throws {
        let client = makeClient(status: 200, body: printerProfilesResponse())

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.id, 1)
        XCTAssertEqual(profiles.first?.printerMakeModel, "Example Printer")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
        XCTAssertEqual(profiles.first?.inkType, "Pigment")
    }

    func testFetchColorsRequestsProfileIDQueryAndDecodesEnvelope() async throws {
        let client = makeClient(status: 200, body: colorsResponse())

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(requests.paths, ["/api/v1/colors"])
        XCTAssertEqual(requests.queryItems["printer_profile_id"], "7")
        XCTAssertEqual(fetched.profile?.id, 7)
        XCTAssertEqual(fetched.colors.first?.id, 123)
        XCTAssertEqual(fetched.colors.first?.responses["red"]?.brightness, 0.87)
    }

    func testFetchColorsWithoutBearerTokenOmitsAuthorizationHeader() async throws {
        let client = makeClient(token: nil, status: 200, body: colorsResponse())

        _ = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(requests.headers(named: "Authorization"), [nil])
    }

    func testWhitespaceOnlyTokenOmitsAuthorizationHeader() async throws {
        let client = makeClient(token: "   ", status: 200, body: printerProfilesResponse())

        _ = try await client.fetchPrinterProfiles()

        XCTAssertEqual(requests.headers(named: "Authorization"), [nil])
    }

    func testRequestsAcceptJSON() async throws {
        let client = makeClient(status: 200, body: printerProfilesResponse())

        _ = try await client.fetchPrinterProfiles()

        XCTAssertEqual(requests.headers(named: "Accept"), ["application/json"])
    }

    func testNon2xxSurfacesBadStatus() async {
        let client = makeClient(status: 500, body: Data())

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    func testUndecodableBodySurfacesMalformedResponse() async {
        let client = makeClient(status: 200, body: Data("not json".utf8))

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testTestConnectionSucceedsOn2xx() async {
        let client = makeClient(status: 204, body: Data())

        await XCTAssertNoThrowAsync(try await client.testConnection())
    }

    func testTestConnectionSurfacesUnauthorized() async {
        let client = makeClient(status: 401, body: Data())

        await XCTAssertThrowsErrorAsync(try await client.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    // MARK: - Fixtures

    private func makeClient(
        token: String? = "  stale-token  ",
        status: Int,
        body: Data,
        inspect: (@Sendable (URLRequest) -> Void)? = nil
    ) -> PaletteAPIClient {
        MockURLProtocol.handler = { request in
            self.requests.append(request)
            inspect?(request)
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (http, body)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return PaletteAPIClient(
            baseURL: URL(string: "http://example.com")!,
            token: token,
            session: URLSession(configuration: configuration)
        )
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

    private func colorsResponse() -> Data {
        """
        {
          "printer_profile": {"id": 7, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"},
          "colors": [
            {
              "id": 123, "name": "Red 12", "hex": "#C64A35",
              "rgb": {"r": 198, "g": 74, "b": 53},
              "palette_id": 5, "palette_name": "Default", "sort_order": 12,
              "responses": {"red": {"brightness": 0.87, "source": "measurement"}}
            }
          ]
        }
        """.data(using: .utf8)!
    }
}

/// Thread-safe record of the requests issued during one test.
private final class RecordedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [Snapshot] = []

    private struct Snapshot {
        var path: String
        var queryItems: [String: String]
        var headers: [String: String?]
    }

    func append(_ request: URLRequest) {
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let snapshot = Snapshot(
            path: components?.path ?? "",
            queryItems: Dictionary(
                uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
            ),
            headers: [
                "Authorization": request.value(forHTTPHeaderField: "Authorization"),
                "Accept": request.value(forHTTPHeaderField: "Accept")
            ]
        )
        lock.lock()
        snapshots.append(snapshot)
        lock.unlock()
    }

    var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return snapshots.map(\.path)
    }

    var queryItems: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return snapshots.first?.queryItems ?? [:]
    }

    func headers(named name: String) -> [String?] {
        lock.lock(); defer { lock.unlock() }
        return snapshots.map { $0.headers[name] ?? nil }
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
