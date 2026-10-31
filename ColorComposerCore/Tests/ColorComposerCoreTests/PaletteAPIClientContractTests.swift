import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Pins the observable HTTP/decoding contract of `PaletteAPIClient` so the
/// migration to the generated OpenAPI client (issue #39) is verified as
/// behavior-preserving: endpoint URLs, headers, auth handling, error
/// mapping, and envelope decoding must be identical before and after.
///
/// These tests are intentionally written against the public client surface —
/// not the generated transport — so they stay valid whether the client wraps
/// or replaces its transport with the generated code.
final class PaletteAPIClientContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        ContractStubURLProtocol.handler = nil
    }

    // MARK: - printer_profiles endpoint

    func testFetchPrinterProfilesHitsVersionedEndpointWithJSONAccept() async throws {
        let (client, requests) = recordingClient(body: printerProfilesBody())

        _ = try await client.fetchPrinterProfiles()

        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
        XCTAssertEqual(request.url?.query, nil)
        XCTAssertTrue(request.httpMethod == nil || request.httpMethod == "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testFetchPrinterProfilesDecodesEnvelope() async throws {
        let client = makeClient(body: printerProfilesBody())

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.map(\.id), [1, 2])
        XCTAssertEqual(profiles.first?.printerMakeModel, "Example Printer")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
        XCTAssertEqual(profiles.first?.inkType, "Pigment")
    }

    // MARK: - colors endpoint

    func testFetchColorsHitsVersionedEndpointWithProfileQuery() async throws {
        let (client, requests) = recordingClient(body: colorsBody())

        _ = try await client.fetchColors(printerProfileID: 42)

        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/colors")
        XCTAssertEqual(request.url?.query, "printer_profile_id=42")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testFetchColorsDecodesColorsAndProfileEnvelope() async throws {
        let client = makeClient(body: colorsBody())

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(fetched.colors.map(\.id), [123])
        XCTAssertEqual(fetched.colors.first?.hex, "#C64A35")
        XCTAssertEqual(fetched.colors.first?.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(fetched.profile?.id, 1)
    }

    /// Colors without measurements come back response-less; exclusion is the
    /// solver's policy, not the client's — the client must not drop or
    /// fabricate entries.
    func testFetchColorsKeepsResponselessColorsForDownstreamExclusion() async throws {
        let client = makeClient(body: colorsBody())

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertNil(fetched.colors.first?.responses["green"])
        XCTAssertNil(fetched.colors.first?.responses["white"])
    }

    func testFetchColorsDecodesProfilelessEnvelope() async throws {
        let client = makeClient(
            body: #"{"colors":[{"id":9,"hex":"#112233","responses":{}}]}"#.data(using: .utf8)!
        )

        let fetched = try await client.fetchColors(printerProfileID: 9)

        XCTAssertEqual(fetched.colors.map(\.id), [9])
        XCTAssertNil(fetched.profile)
    }

    // MARK: - Error mapping

    func testFetchColorsMapsUnauthorizedToReauthError() async {
        let client = makeClient(status: 401, body: Data())

        await assertAsyncThrows(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testFetchColorsMapsServerErrorsToBadStatus() async {
        let client = makeClient(status: 503, body: Data())

        await assertAsyncThrows(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testMalformedBodyThrowsMalformedResponse() async {
        let client = makeClient(body: Data("not json".utf8))

        await assertAsyncThrows(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - Auth header handling

    func testOmittedTokenSendsNoAuthorizationHeader() async throws {
        let (client, requests) = recordingClient(token: nil, body: printerProfilesBody())

        _ = try await client.fetchPrinterProfiles()

        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testBlankTokenSendsNoAuthorizationHeader() async throws {
        let (client, requests) = recordingClient(token: "   \n", body: printerProfilesBody())

        _ = try await client.fetchPrinterProfiles()

        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testBearerTokenIsSentTrimmed() async throws {
        let (client, requests) = recordingClient(token: "  abc-123  ", body: printerProfilesBody())

        _ = try await client.fetchPrinterProfiles()

        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer abc-123")
    }

    // MARK: - Base URL handling

    func testBaseURLSubpathAndTrailingSlashStillResolveAPIV1() async throws {
        let (client, requests) = recordingClient(
            base: URL(string: "http://example.com/prefix/")!,
            body: printerProfilesBody()
        )

        _ = try await client.fetchPrinterProfiles()

        XCTAssertEqual(requests.first?.url?.path, "/prefix/api/v1/printer_profiles")
    }

    // MARK: - Wire tolerance

    /// The server spec is allowed to grow new fields; unknown keys must not
    /// break decoding (the generated client tolerates them the same way).
    func testEnvelopeToleratesUnknownFields() async throws {
        let future = #"{"printer_profiles":[{"id":1,"printer_make_model":"Epson","paper_type":"Matte","ink_type":"Dye","new_field":true}],"new_envelope_field":"x"}"#
        let client = makeClient(body: future.data(using: .utf8)!)

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.map(\.id), [1])
    }

    /// Unknown light-source keys inside `responses` must not break the fetch;
    /// they are dropped only at domain conversion.
    func testFetchColorsToleratesUnknownLightSourceKeys() async throws {
        let json = #"{"colors":[{"id":5,"hex":"#abcdef","rgb":{"r":171,"g":205,"b":239},"responses":{"red":{"brightness":0.5},"ultraviolet":{"brightness":0.9}}}]}"#
        let client = makeClient(body: json.data(using: .utf8)!)

        let fetched = try await client.fetchColors(printerProfileID: 5)

        XCTAssertEqual(fetched.colors.first?.responses["red"]?.brightness, 0.5)
        let domain = try XCTUnwrap(fetched.colors.first?.toDomain())
        XCTAssertEqual(domain.brightness(for: .red), 0.5)
        XCTAssertNil(domain.brightness(for: .green))
    }

    // MARK: - Connection test

    func testTestConnectionSucceedsOnNoContent() async {
        let client = makeClient(status: 204, body: Data())

        await assertAsyncNoThrow(try await client.testConnection())
    }

    func testTestConnectionMapsUnauthorized() async {
        let client = makeClient(status: 401, body: Data())

        await assertAsyncThrows(try await client.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    // MARK: - Helpers

    private func makeClient(
        base: URL = URL(string: "http://example.com")!,
        token: String? = "token-1",
        status: Int = 200,
        body: Data
    ) -> PaletteAPIClient {
        ContractStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContractStubURLProtocol.self]
        return PaletteAPIClient(
            baseURL: base,
            token: token,
            session: URLSession(configuration: configuration)
        )
    }

    private func recordingClient(
        base: URL = URL(string: "http://example.com")!,
        token: String? = "token-1",
        status: Int = 200,
        body: Data
    ) -> (PaletteAPIClient, LockedRequestLog) {
        let log = LockedRequestLog()
        ContractStubURLProtocol.handler = { request in
            log.append(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContractStubURLProtocol.self]
        let client = PaletteAPIClient(
            baseURL: base,
            token: token,
            session: URLSession(configuration: configuration)
        )
        return (client, log)
    }

    private func printerProfilesBody() -> Data {
        """
        {"printer_profiles":[
          {"id":1,"printer_make_model":"Example Printer","paper_type":"Matte","ink_type":"Pigment"},
          {"id":2,"printer_make_model":"Other Printer","paper_type":"Glossy","ink_type":"Dye"}
        ]}
        """.data(using: .utf8)!
    }

    private func colorsBody() -> Data {
        """
        {"printer_profile":{"id":1,"printer_make_model":"Epson","paper_type":"Matte","ink_type":"Dye"},
         "colors":[{"id":123,"name":"Red 12","hex":"#C64A35","rgb":{"r":198,"g":74,"b":53},
           "responses":{"red":{"brightness":0.87,"source":"measurement"},"lps":{"brightness":0.52,"source":"response"}}}]}
        """.data(using: .utf8)!
    }
}

/// Thread-safe request log shared with the stub protocol handler.
private final class LockedRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    var first: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests.first
    }
}

private final class ContractStubURLProtocol: URLProtocol, @unchecked Sendable {
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

private func assertAsyncThrows<T>(
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
