import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Pins `PaletteAPIClient`'s observable wire behavior so the migration to the
/// generated OpenAPI client (issue #39) cannot change it: endpoint URLs, the
/// `printer_profile_id` query, bearer-token handling, status-to-error
/// mapping, and snake_case envelope decoding. The disk cache and offline
/// fallback built on top of this client depend on all of it (see
/// `ProfileColorCacheTests`).
final class PaletteAPIClientBehaviorTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        StubURLProtocol.handler = nil
    }

    private func makeClient(
        token: String? = "  stale-token  ",
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        StubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(
            baseURL: URL(string: "http://example.com/base")!,
            token: token,
            session: session
        )
    }

    private func respond(_ body: Data, status: Int = 200) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in (.init(statusCode: status, url: request.url!), body) }
    }

    // MARK: - fetchPrinterProfiles

    func testFetchPrinterProfilesHitsVersionedEndpointAndDecodesSnakeCaseEnvelope() async throws {
        let client = makeClient(handler: respond(Data(#"{"printer_profiles":[{"id":1,"printer_make_model":"Epson","paper_type":"Matte","ink_type":"Pigment"}]}"#.utf8)))

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.absoluteString, "http://example.com/base/api/v1/printer_profiles")
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(profiles.map(\.id), [1])
        XCTAssertEqual(profiles.first?.printerMakeModel, "Epson")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
        XCTAssertEqual(profiles.first?.inkType, "Pigment")
    }

    func testFetchPrinterProfilesMapsServerErrorToBadStatus() async {
        let client = makeClient(handler: respond(Data(), status: 503))

        await assertAsyncThrowsError(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testFetchPrinterProfilesMapsUnparseableBodyToMalformedResponse() async {
        let client = makeClient(handler: respond(Data("not json".utf8)))

        await assertAsyncThrowsError(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testFetchPrinterProfilesSendsNoAuthorizationHeaderWithoutToken() async throws {
        let client = makeClient(token: nil, handler: respond(Data(#"{"printer_profiles":[]}"#.utf8)))

        _ = try await client.fetchPrinterProfiles()

        XCTAssertNil(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testWhitespaceOnlyTokenIsTreatedAsAbsent() async throws {
        let client = makeClient(token: "   \n", handler: respond(Data(#"{"printer_profiles":[]}"#.utf8)))

        _ = try await client.fetchPrinterProfiles()

        XCTAssertNil(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - fetchColors

    func testFetchColorsSendsProfileQueryAndDecodesEnvelope() async throws {
        let client = makeClient(handler: respond(Data("""
        {
          "printer_profile": {"id": 4, "printer_make_model": "Canon", "paper_type": "Glossy", "ink_type": "Dye"},
          "colors": [
            {"id": 123, "name": "Red 12", "hex": "#C64A35", "rgb": {"r": 198, "g": 74, "b": 53},
             "palette_id": 5, "palette_name": "Default", "sort_order": 12,
             "responses": {"red": {"brightness": 0.87, "source": "measurement"}, "lps": {"brightness": 0.52}}}
          ]
        }
        """.utf8)))

        let fetched = try await client.fetchColors(printerProfileID: 4)

        XCTAssertEqual(
            StubURLProtocol.lastRequest?.url?.absoluteString,
            "http://example.com/base/api/v1/colors?printer_profile_id=4"
        )
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer stale-token")
        XCTAssertEqual(fetched.colors.map(\.id), [123])
        XCTAssertEqual(fetched.colors.first?.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(fetched.profile?.id, 4)
        XCTAssertEqual(fetched.profile?.paperType, "Glossy")
    }

    /// The envelope's `printer_profile` is optional client-side even though
    /// the OpenAPI schema marks it required; a response without it must still
    /// decode so the cached-profile fallback can store what it got.
    func testFetchColorsDecodesEnvelopeWithoutProfile() async throws {
        let client = makeClient(handler: respond(Data(#"{"colors":[{"id":7,"name":null,"hex":"#abcdef","rgb":{"r":171,"g":205,"b":239},"palette_id":null,"palette_name":null,"sort_order":null,"responses":{"green":{"brightness":0.4}}}]}"#.utf8)))

        let fetched = try await client.fetchColors(printerProfileID: 9)

        XCTAssertNil(fetched.profile)
        XCTAssertEqual(fetched.colors.map(\.id), [7])
    }

    func testFetchColorsMapsUnauthorizedToUnauthorizedError() async {
        let client = makeClient(handler: respond(Data(), status: 401))

        await assertAsyncThrowsError(try await client.fetchColors(printerProfileID: 4)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testFetchColorsMapsUnparseableBodyToMalformedResponse() async {
        let client = makeClient(handler: respond(Data("{".utf8)))

        await assertAsyncThrowsError(try await client.fetchColors(printerProfileID: 4)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - testConnection

    func testTestConnectionSucceedsOnAny2xx() async {
        let client = makeClient(handler: respond(Data(#"{"printer_profiles":[]}"#.utf8), status: 204))

        await assertAsyncNoThrow(try await client.testConnection())
    }

    func testTestConnectionSurfacesUnauthorized() async {
        let client = makeClient(handler: respond(Data(), status: 401))

        await assertAsyncThrowsError(try await client.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testTestConnectionSurfacesBadStatus() async {
        let client = makeClient(handler: respond(Data(), status: 500))

        await assertAsyncThrowsError(try await client.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) private static var lastRecordedRequest: URLRequest?

    static var lastRequest: URLRequest? { lastRecordedRequest }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lastRecordedRequest = request
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

private func assertAsyncThrowsError<T>(
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

private func assertAsyncNoThrow<T>(
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
