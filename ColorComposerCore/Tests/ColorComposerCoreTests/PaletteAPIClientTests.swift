import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// The palette API client is moving onto a client generated from the server's
/// published OpenAPI document. These tests pin the behavior the app depends
/// on, so the migration cannot change it: the documented endpoints, the
/// bearer token, the error mapping the UI reacts to, and the decoded
/// envelope.
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
        let recorder = RequestRecorder()
        let client = makeClient { request in
            recorder.record(request)
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesResponse())
        }

        _ = try await client.fetchPrinterProfiles()

        XCTAssertEqual(recorder.requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer stale-token"])
    }

    // MARK: - Documented endpoints

    /// The client must keep talking to the endpoint the published OpenAPI
    /// document describes: `GET /api/v1/printer_profiles`.
    func testFetchPrinterProfilesRequestsTheDocumentedEndpoint() async throws {
        let recorder = RequestRecorder()
        let client = makeClient { request in
            recorder.record(request)
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesResponse())
        }

        _ = try await client.fetchPrinterProfiles()

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    /// Colors are fetched per printer profile: `GET
    /// /api/v1/colors?printer_profile_id=N`.
    func testFetchColorsRequestsTheDocumentedProfileQuery() async throws {
        let recorder = RequestRecorder()
        let client = makeClient { request in
            recorder.record(request)
            return (.init(statusCode: 200, url: request.url!), Self.colorsResponse())
        }

        _ = try await client.fetchColors(printerProfileID: 42)

        let request = try XCTUnwrap(recorder.requests.first)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/api/v1/colors")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(
            components.queryItems?.first { $0.name == "printer_profile_id" }?.value,
            "42"
        )
    }

    /// The documented envelope carries the profile alongside the colors; both
    /// must survive the round trip through the client.
    func testFetchColorsDecodesTheDocumentedEnvelope() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsResponse())
        }

        let envelope = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(envelope.profile?.id, 1)
        XCTAssertEqual(envelope.profile?.printerMakeModel, "Epson")
        XCTAssertEqual(envelope.colors.count, 1)
        XCTAssertEqual(envelope.colors.first?.hex, "#C64A35")
        XCTAssertEqual(envelope.colors.first?.responses["red"]?.brightness, 0.87)
    }

    /// The reachability probe must accept any success status from the
    /// documented profiles endpoint.
    func testTestConnectionAcceptsAnySuccessStatus() async throws {
        let client = makeClient { request in
            (.init(statusCode: 204, url: request.url!), Data())
        }

        try await client.testConnection()
    }

    // MARK: - Error mapping

    /// Failures other than an expired token keep their status code so the UI
    /// can tell "server is down" from "token rejected".
    func testServerFailureSurfacesItsStatusCode() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testMissingProfileSurfacesItsStatusCode() async {
        let client = makeClient { request in
            (.init(statusCode: 404, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 99)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(404))
        }
    }

    /// A body that does not match the documented envelope is a malformed
    /// response, not a status failure.
    func testMalformedBodySurfacesMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - Helpers

    private func makeClient(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(baseURL: URL(string: "http://example.com")!, token: "  stale-token  ", session: session)
    }

    private static func printerProfilesResponse() -> Data {
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

    /// The documented `ColorsResponse` envelope: the profile plus the
    /// measured colors.
    private static func colorsResponse() -> Data {
        """
        {
          "printer_profile": {
            "id": 1, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"
          },
          "colors": [
            {
              "id": 123, "name": "Red 12", "hex": "#C64A35",
              "rgb": {"r": 198, "g": 74, "b": 53},
              "palette_id": 5, "palette_name": "Default", "sort_order": 12,
              "responses": {
                "red": {"brightness": 0.87, "source": "measurement", "raw_value": null,
                        "raw_unit": null, "apparent_brightness": null, "measured_at": null,
                        "test_run_id": null}
              }
            }
          ]
        }
        """.data(using: .utf8)!
    }
}

/// Collects the requests a mocked session sent.
private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ request: URLRequest) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
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
