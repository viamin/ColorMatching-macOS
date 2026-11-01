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

    // MARK: - Wire contract (migration net for the generated OpenAPI client)
    //
    // These tests pin the `/api/v1` request shapes and response envelopes the
    // server publishes as OpenAPI (viamin/color_matching#110): the generated
    // client that replaces the hand-rolled transport must keep every one of
    // them — same URLs, same bearer-token header, same decoded values, same
    // error mapping — for the disk-cache/offline behavior above it to remain
    // unchanged.

    func testFetchPrinterProfilesRequestsAPIV1EndpointAndDecodesEnvelope() async throws {
        let lock = NSLock()
        var urls: [String] = []
        let client = makeClient { request in
            lock.lock()
            urls.append(request.url?.absoluteString ?? "")
            lock.unlock()
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), printerProfilesResponse())
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(urls, ["http://example.com/api/v1/printer_profiles"])
        XCTAssertEqual(profiles.count, 1)
        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.id, 1)
        XCTAssertEqual(profile.printerMakeModel, "Example Printer")
        XCTAssertEqual(profile.paperType, "Matte")
        XCTAssertEqual(profile.inkType, "Pigment")
    }

    func testFetchColorsRequestsColorsEndpointWithProfileIDQuery() async throws {
        let lock = NSLock()
        var urls: [String] = []
        let client = makeClient { request in
            lock.lock()
            urls.append(request.url?.absoluteString ?? "")
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), specConformantColorsResponse())
        }

        let result = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(urls, ["http://example.com/api/v1/colors?printer_profile_id=7"])
        XCTAssertEqual(result.profile?.id, 7)
        XCTAssertEqual(result.profile?.printerMakeModel, "Epson")
        let color = try XCTUnwrap(result.colors.first)
        XCTAssertEqual(color.id, 123)
        XCTAssertEqual(color.name, "Red 12")
        XCTAssertEqual(color.hex, "#C64A35")
        XCTAssertEqual(color.paletteName, nil)
        XCTAssertEqual(color.responses["red"]?.brightness ?? 0, 0.87, accuracy: 1e-12)
        XCTAssertNil(color.responses["green"])
    }

    /// Decodes a payload carrying exactly the required `ColorsResponse`
    /// fields from the published spec (id, name, hex, palette_id, sort_order,
    /// responses — plus a nullable palette_name and omitted optional rgb).
    func testFetchColorsDecodesSpecConformantColorsResponse() async throws {
        let json = """
        {
          "printer_profile": {"id": 7, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"},
          "colors": [
            {
              "id": 9, "name": "Ultramarine", "hex": "#12005E",
              "palette_id": 5, "palette_name": null, "sort_order": 3,
              "responses": {"lps": {"brightness": 0.25, "source": "response"}}
            }
          ]
        }
        """
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data(json.utf8))
        }

        let result = try await client.fetchColors(printerProfileID: 7)

        let color = try XCTUnwrap(result.colors.first)
        XCTAssertEqual(color.rgb, nil)
        XCTAssertEqual(color.paletteId, 5)
        XCTAssertEqual(color.sortOrder, 3)
        XCTAssertEqual(color.responses["lps"]?.source, "response")
    }

    func testFetchColorsThrowsBadStatusOnServerFailure() async {
        let client = makeClient { request in
            (.init(statusCode: 500, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    func testFetchColorsThrowsMalformedResponseOnUndecodableBody() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testTestConnectionSucceedsOn2xx() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), printerProfilesResponse())
        }

        try await client.testConnection()
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

    /// A `ColorsResponse` payload carrying the fields the published OpenAPI
    /// spec requires (plus optional `rgb`).
    private func specConformantColorsResponse() -> Data {
        """
        {
          "printer_profile": {
            "id": 7, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"
          },
          "colors": [
            {
              "id": 123, "name": "Red 12", "hex": "#C64A35",
              "rgb": {"r": 198, "g": 74, "b": 53},
              "palette_id": 5, "palette_name": null, "sort_order": 12,
              "responses": {
                "red": {"brightness": 0.87, "source": "measurement"}
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
