import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire-contract pins for the migration to the generated OpenAPI client
/// (issue #39): whatever backs `PaletteAPIClient` after the migration, these
/// request shapes, decodings, and error mappings must hold unchanged.
final class PaletteAPIClientContractTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.resetRecordedRequests()
        super.tearDown()
    }

    private func makeClient(
        token: String? = nil,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return PaletteAPIClient(
            baseURL: URL(string: "http://example.com")!,
            token: token,
            session: URLSession(configuration: configuration)
        )
    }

    /// Records every request the client issues so tests can pin the exact
    /// `/api/v1` request shape.
    private func recordingHandler(
        payload: Data
    ) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            MockURLProtocol.record(request)
            return (.init(statusCode: 200, url: request.url!), payload)
        }
    }

    // MARK: - printer_profiles

    func testFetchPrinterProfilesRequestsApiV1PrinterProfilesPath() async throws {
        let client = makeClient(handler: recordingHandler(payload: printerProfilesResponse()))

        let profiles = try await client.fetchPrinterProfiles()

        let request = try XCTUnwrap(MockURLProtocol.recordedRequests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "No token configured: no Authorization header.")

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.id, 1)
        XCTAssertEqual(profiles.first?.printerMakeModel, "Example Printer")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
        XCTAssertEqual(profiles.first?.inkType, "Pigment")
        XCTAssertEqual(profiles.first?.displayName, "Example Printer · Matte · Pigment")
    }

    func testTestConnectionPingsApiV1PrinterProfiles() async throws {
        let client = makeClient(handler: recordingHandler(payload: printerProfilesResponse()))

        try await client.testConnection()

        let request = try XCTUnwrap(MockURLProtocol.recordedRequests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
    }

    // MARK: - colors

    func testFetchColorsRequestsApiV1ColorsWithPrinterProfileQuery() async throws {
        let client = makeClient(handler: recordingHandler(payload: colorsResponse()))

        let fetched = try await client.fetchColors(printerProfileID: 7)

        let request = try XCTUnwrap(MockURLProtocol.recordedRequests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/colors")
        let query = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query, [URLQueryItem(name: "printer_profile_id", value: "7")])

        XCTAssertEqual(fetched.colors.count, 1)
        XCTAssertEqual(fetched.colors.first?.id, 123)
        XCTAssertEqual(fetched.colors.first?.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(fetched.profile?.id, 1)
    }

    func testFetchColorsSendsBearerTokenWhenConfigured() async throws {
        let client = makeClient(token: "secret", handler: recordingHandler(payload: colorsResponse()))

        _ = try await client.fetchColors(printerProfileID: 7)

        let request = try XCTUnwrap(MockURLProtocol.recordedRequests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }

    func testFetchColorsMaps401ToUnauthorized() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testFetchColorsMapsUndecodableBodyToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - Fixtures

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
          "printer_profile": {
            "id": 1,
            "printer_make_model": "Epson",
            "paper_type": "Matte",
            "ink_type": "Dye"
          },
          "colors": [
            {
              "id": 123,
              "name": "Red 12",
              "hex": "#C64A35",
              "rgb": {"r": 198, "g": 74, "b": 53},
              "responses": {
                "red": {"brightness": 0.87},
                "lps": {"brightness": 0.52}
              }
            }
          ]
        }
        """.data(using: .utf8)!
    }
}

/// Shared request recorder + mock transport for the wire-contract tests.
private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var _handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) private static var _recordedRequests: [URLRequest] = []
    private static let lock = NSLock()

    static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); defer { lock.unlock() }; _handler = newValue }
    }

    static var recordedRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _recordedRequests
    }

    static func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        _recordedRequests.append(request)
    }

    static func resetRecordedRequests() {
        lock.lock(); defer { lock.unlock() }
        _recordedRequests.removeAll()
    }

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
