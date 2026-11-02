import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire contract of `PaletteAPIClient` against `color_matching` `/api/v1`.
///
/// These pins are the acceptance net for the generated-OpenAPI-client
/// migration (issue #39): whether `PaletteAPIClient` is rebuilt on
/// swift-openapi-runtime or wraps a generated `Client`, it must keep issuing
/// exactly these requests and mapping failures to exactly these errors, so
/// the app's disk-cache and offline-stale behavior is unaffected.
final class PaletteAPIWireContractTests: XCTestCase {
    fileprivate struct RecordedRequest {
        var url: URL
        var method: String
        var authorization: String?
        var accept: String?
    }

    private var recorder = RequestRecorder()

    override func tearDown() {
        super.tearDown()
        WireContractMockURLProtocol.handler = nil
    }

    private func makeClient(
        token: String?,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        WireContractMockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WireContractMockURLProtocol.self]
        return PaletteAPIClient(
            baseURL: URL(string: "http://example.com")!,
            token: token,
            session: URLSession(configuration: configuration)
        )
    }

    /// A handler that records every request and replies with `status`/`body`.
    private func recordingHandler(
        status: Int = 200,
        body: Data
    ) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        let recorder = recorder
        return { request in
            recorder.record(request)
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
        }
    }

    private func firstRecordedRequest(file: StaticString = #filePath, line: UInt = #line) throws -> RecordedRequest {
        let requests = recorder.all()
        XCTAssertEqual(requests.count, 1, "expected exactly one request", file: file, line: line)
        return try XCTUnwrap(requests.first, file: file, line: line)
    }

    // MARK: - GET /api/v1/printer_profiles

    func testFetchPrinterProfilesSendsCanonicalRequestAndDecodesEnvelope() async throws {
        let client = makeClient(token: "  wire-token  ", handler: recordingHandler(body: printerProfilesBody()))

        let profiles = try await client.fetchPrinterProfiles()

        let request = try firstRecordedRequest()
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.absoluteString, "http://example.com/api/v1/printer_profiles")
        XCTAssertEqual(request.authorization, "Bearer wire-token",
                       "bearer token must be whitespace-trimmed and sent as `Bearer <token>`")
        XCTAssertEqual(request.accept, "application/json")

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.id, 1)
        XCTAssertEqual(profiles.first?.printerMakeModel, "Example Printer")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
        XCTAssertEqual(profiles.first?.inkType, "Pigment")
    }

    // MARK: - GET /api/v1/colors?printer_profile_id=N

    func testFetchColorsSendsProfileIDQueryAndDecodesEnvelope() async throws {
        let client = makeClient(token: "wire-token", handler: recordingHandler(body: colorsBody()))

        let fetched = try await client.fetchColors(printerProfileID: 7)

        let request = try firstRecordedRequest()
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.absoluteString, "http://example.com/api/v1/colors?printer_profile_id=7",
                       "the profile id must travel as the `printer_profile_id` query parameter")
        XCTAssertEqual(request.authorization, "Bearer wire-token")
        XCTAssertEqual(request.accept, "application/json")

        XCTAssertEqual(fetched.profile?.id, 7)
        XCTAssertEqual(fetched.colors.count, 1)
        let color = try XCTUnwrap(fetched.colors.first)
        XCTAssertEqual(color.id, 123)
        XCTAssertEqual(color.name, "Red 12")
        XCTAssertEqual(color.hex, "#C64A35")
        XCTAssertEqual(color.rgb?.r, 198)
        XCTAssertEqual(color.rgb?.g, 74)
        XCTAssertEqual(color.rgb?.b, 53)
        XCTAssertEqual(color.responses["red"]?.brightness, 0.87)
        XCTAssertNil(color.responses["green"], "unmeasured conditions are absent, never zero")
    }

    func testFetchColorsWithoutTokenOmitsAuthorizationHeader() async throws {
        let client = makeClient(token: nil, handler: recordingHandler(body: colorsBody()))

        _ = try await client.fetchColors(printerProfileID: 7)

        let request = try firstRecordedRequest()
        XCTAssertNil(request.authorization)
    }

    func testFetchColorsWithBlankTokenOmitsAuthorizationHeader() async throws {
        let client = makeClient(token: "   ", handler: recordingHandler(body: colorsBody()))

        _ = try await client.fetchColors(printerProfileID: 7)

        let request = try firstRecordedRequest()
        XCTAssertNil(request.authorization, "a whitespace-only token is no token")
    }

    // MARK: - Failure mapping

    func testFetchColorsMaps401ToUnauthorized() async {
        let client = makeClient(token: "stale", handler: statusHandler(401))

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized,
                           "HTTP 401 must surface as .unauthorized so the app can offer re-authentication")
        }
    }

    func testFetchColorsMapsNon2xxToBadStatus() async {
        let client = makeClient(token: "t", handler: recordingHandler(status: 503, body: Data("[]".utf8)))

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testFetchColorsMapsUndecodableBodyToMalformedResponse() async {
        let client = makeClient(token: "t", handler: recordingHandler(body: Data("not json".utf8)))

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - Reachability probe

    func testTestConnectionProbesPrinterProfilesEndpoint() async throws {
        let client = makeClient(token: "t", handler: recordingHandler(body: printerProfilesBody()))

        try await client.testConnection()

        let request = try firstRecordedRequest()
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.absoluteString, "http://example.com/api/v1/printer_profiles")
    }

    // MARK: - Fixtures

    private func printerProfilesBody() -> Data {
        """
        {"printer_profiles":[{"id":1,"printer_make_model":"Example Printer","paper_type":"Matte","ink_type":"Pigment"}]}
        """.data(using: .utf8)!
    }

    private func colorsBody() -> Data {
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

    private func statusHandler(_ status: Int) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data())
        }
    }
}

/// Collects requests under a lock so `@Sendable` handlers can record safely.
private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [PaletteAPIWireContractTests.RecordedRequest] = []

    func record(_ request: URLRequest) {
        let entry = PaletteAPIWireContractTests.RecordedRequest(
            url: request.url!,
            method: request.httpMethod ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            accept: request.value(forHTTPHeaderField: "Accept")
        )
        lock.lock()
        requests.append(entry)
        lock.unlock()
    }

    func all() -> [PaletteAPIWireContractTests.RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class WireContractMockURLProtocol: URLProtocol, @unchecked Sendable {
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
