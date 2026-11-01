import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Behavioral safety net for the generated OpenAPI client migration (#39).
///
/// These tests pin the observable behavior of `PaletteAPIClient` — request
/// shapes against `/api/v1`, bearer-token handling, snake_case envelope
/// decoding, and error mapping — so that migrating the transport onto the
/// swift-openapi-generator client (or wrapping it) cannot change what the
/// app observes. They pass against the hand-written client today and must
/// keep passing after the migration; the disk-cache and offline-stale layers
/// (`ProfileColorCache` + `ColorCatalog`) sit above this boundary and are
/// covered by `ProfileColorCacheTests`.
final class PaletteAPIClientContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.handler = nil
    }

    private func makeClient(
        token: String? = "  tok-123  ",
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

    private static func httpResponse(statusCode: Int, request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    private static func ok(_ request: URLRequest, _ body: Data) -> (HTTPURLResponse, Data) {
        (httpResponse(statusCode: 200, request: request), body)
    }

    // MARK: - GET /api/v1/colors

    func testFetchColorsBuildsV1RequestWithProfileQueryTokenAndAccept() async throws {
        let lock = NSLock()
        var recorded: [URLRequest] = []
        let client = makeClient { request in
            lock.lock()
            recorded.append(request)
            lock.unlock()
            return Self.ok(request, Self.emptyColorsEnvelope)
        }

        _ = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(recorded.count, 1)
        let request = try XCTUnwrap(recorded.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "http://example.com/api/v1/colors?printer_profile_id=7")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
    }

    func testFetchColorsDecodesSnakeCaseEnvelope() async throws {
        let client = makeClient { request in Self.ok(request, Self.colorsEnvelope) }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(fetched.colors.count, 1)
        let color = try XCTUnwrap(fetched.colors.first)
        XCTAssertEqual(color.id, 123)
        XCTAssertEqual(color.name, "Red 12")
        XCTAssertEqual(color.hex, "#C64A35")
        XCTAssertEqual(color.rgb?.r, 198)
        XCTAssertEqual(color.rgb?.g, 74)
        XCTAssertEqual(color.paletteName, "Default")
        XCTAssertEqual(color.sortOrder, 12)
        XCTAssertEqual(color.responses["red"]?.brightness ?? 0, 0.87, accuracy: 1e-12)
        XCTAssertEqual(color.responses["lps"]?.apparentBrightness, 5)

        let profile = try XCTUnwrap(fetched.profile)
        XCTAssertEqual(profile.id, 7)
        XCTAssertEqual(profile.printerMakeModel, "Epson")
        XCTAssertEqual(profile.paperType, "Matte")
        XCTAssertEqual(profile.inkType, "Dye")
    }

    func testFetchColorsToleratesNullPrinterProfileAndEmptyColorList() async throws {
        let client = makeClient { request in Self.ok(request, Self.emptyColorsEnvelope) }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertTrue(fetched.colors.isEmpty)
        XCTAssertNil(fetched.profile)
    }

    func testFetchColorsMapsHTTP401ToUnauthorized() async {
        let client = makeClient { request in
            (Self.httpResponse(statusCode: 401, request: request), Data())
        }

        await assertAsyncThrows(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testFetchColorsMapsNon2xxToBadStatus() async {
        let client = makeClient { request in
            (Self.httpResponse(statusCode: 503, request: request), Data())
        }

        await assertAsyncThrows(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testFetchColorsMapsUndecodableBodyToMalformedResponse() async {
        let client = makeClient { request in Self.ok(request, Data("not json".utf8)) }

        await assertAsyncThrows(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - GET /api/v1/printer_profiles

    func testFetchPrinterProfilesHitsV1EndpointAndDecodesEnvelope() async throws {
        let lock = NSLock()
        var recordedURLs: [String] = []
        let client = makeClient { request in
            lock.lock()
            recordedURLs.append(request.url?.absoluteString ?? "")
            lock.unlock()
            return Self.ok(
                request,
                Data(
                    """
                    {"printer_profiles":[
                      {"id":1,"printer_make_model":"Example Printer","paper_type":"Matte","ink_type":"Pigment"},
                      {"id":2,"printer_make_model":null,"paper_type":null,"ink_type":null}
                    ]}
                    """.utf8
                )
            )
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(recordedURLs, ["http://example.com/api/v1/printer_profiles"])
        XCTAssertEqual(profiles.map(\.id), [1, 2])
        XCTAssertEqual(profiles.first?.printerMakeModel, "Example Printer")
        XCTAssertNil(profiles.last?.printerMakeModel)
    }

    // MARK: - Token handling

    func testOmittedTokenSendsNoAuthorizationHeader() async throws {
        let lock = NSLock()
        var headers: [String?] = []
        let client = makeClient(token: nil) { request in
            lock.lock()
            headers.append(request.value(forHTTPHeaderField: "Authorization"))
            lock.unlock()
            return Self.ok(request, Self.emptyColorsEnvelope)
        }

        _ = try await client.fetchColors(printerProfileID: 1)

        XCTAssertEqual(headers.count, 1)
        XCTAssertNil(headers.first)
    }

    // MARK: - Test connection

    func testTestConnectionSucceedsOn2xx() async {
        let client = makeClient { request in
            (Self.httpResponse(statusCode: 204, request: request), Data())
        }

        do {
            try await client.testConnection()
        } catch {
            XCTFail("Expected testConnection() to succeed on 2xx, got \(error)")
        }
    }

    func testTestConnectionMaps401ToUnauthorized() async {
        let client = makeClient { request in
            (Self.httpResponse(statusCode: 401, request: request), Data())
        }

        await assertAsyncThrows(try await client.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    // MARK: - Fixtures

    private static let colorsEnvelope = Data(
        """
        {
          "printer_profile": {
            "id": 7, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"
          },
          "colors": [
            {
              "id": 123, "name": "Red 12", "hex": "#C64A35",
              "rgb": {"r": 198, "g": 74, "b": 53},
              "palette_id": 5, "palette_name": "Default", "sort_order": 12,
              "responses": {
                "red": {"brightness": 0.87, "source": "measurement"},
                "lps": {"brightness": 0.52, "source": "response", "apparent_brightness": 5}
              }
            }
          ]
        }
        """.utf8
    )

    private static let emptyColorsEnvelope = Data(
        #"{"colors": [], "printer_profile": null}"#.utf8
    )
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
