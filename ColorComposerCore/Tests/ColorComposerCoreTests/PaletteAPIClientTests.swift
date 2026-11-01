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

    // MARK: - Wire contract the generated-client migration must preserve (#39)

    /// `fetchColors` must keep hitting exactly `/api/v1/colors?printer_profile_id=N`
    /// with the JSON `Accept` header and the trimmed bearer token, and keep
    /// decoding the snake_case envelope into wire DTOs unchanged.
    func testFetchColorsRequestsScopedEndpointAndDecodesEnvelope() async throws {
        let lock = NSLock()
        var captured: [(url: String, accept: String?, authorization: String?)] = []
        let client = makeClient { request in
            lock.lock()
            captured.append((
                request.url?.absoluteString ?? "",
                request.value(forHTTPHeaderField: "Accept"),
                request.value(forHTTPHeaderField: "Authorization")
            ))
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), colorsResponse())
        }

        let (colors, profile) = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.url, "http://example.com/api/v1/colors?printer_profile_id=7")
        XCTAssertEqual(captured.first?.accept, "application/json")
        XCTAssertEqual(captured.first?.authorization, "Bearer stale-token")

        XCTAssertEqual(colors.count, 1)
        let color = try XCTUnwrap(colors.first)
        XCTAssertEqual(color.id, 123)
        XCTAssertEqual(color.hex, "#C64A35")
        XCTAssertEqual(color.rgb?.r, 198)
        XCTAssertEqual(color.rgb?.g, 74)
        XCTAssertEqual(color.rgb?.b, 53)
        XCTAssertEqual(color.paletteName, "Default")
        XCTAssertEqual(color.responses["red"]?.brightness ?? -1, 0.87, accuracy: 1e-12)
        XCTAssertEqual(color.responses["lps"]?.brightness ?? -1, 0.52, accuracy: 1e-12)
        XCTAssertNil(color.responses["green"], "Unmeasured conditions stay absent, not zero")

        let unwrappedProfile = try XCTUnwrap(profile)
        XCTAssertEqual(unwrappedProfile.id, 7)
        XCTAssertEqual(unwrappedProfile.printerMakeModel, "Epson SC700")
        XCTAssertEqual(unwrappedProfile.paperType, "Matte")
        XCTAssertEqual(unwrappedProfile.inkType, "Pigment")
    }

    /// The envelope's `printer_profile` is optional; a response without one
    /// must decode with a `nil` profile rather than failing.
    func testFetchColorsDecodesEnvelopeWithoutProfile() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), colorsResponseWithoutProfile())
        }

        let (colors, profile) = try await client.fetchColors(printerProfileID: 1)

        XCTAssertEqual(colors.count, 1)
        XCTAssertNil(profile)
    }

    func testFetchColorsMaps401ToUnauthorized() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testFetchColorsMapsNon2xxToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testFetchColorsMapsUndecodableBodyToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("{ not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testFetchPrinterProfilesDecodesSnakeCaseEnvelopeFields() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), printerProfilesResponse())
        }

        let profiles = try await client.fetchPrinterProfiles()

        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.id, 1)
        XCTAssertEqual(profile.printerMakeModel, "Example Printer")
        XCTAssertEqual(profile.paperType, "Matte")
        XCTAssertEqual(profile.inkType, "Pigment")
    }

    /// A blank or absent token must not send an `Authorization` header at all.
    func testBlankTokenSendsNoAuthorizationHeader() async throws {
        let lock = NSLock()
        var authorizations: [String?] = []
        let client = makeClient(token: "   ") { request in
            lock.lock()
            authorizations.append(request.value(forHTTPHeaderField: "Authorization"))
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), printerProfilesResponse())
        }

        _ = try await client.fetchPrinterProfiles()

        XCTAssertEqual(authorizations, [nil])
    }

    /// `testConnection` is the "Test connection" UI action: any 2xx from
    /// `/api/v1/printer_profiles` (including empty 204s) counts as reachable.
    func testTestConnectionAcceptsAny2xxFromPrinterProfilesEndpoint() async throws {
        let lock = NSLock()
        var paths: [String] = []
        let client = makeClient(token: nil) { request in
            lock.lock()
            paths.append(request.url?.path ?? "")
            lock.unlock()
            return (.init(statusCode: 204, url: request.url!), Data())
        }

        try await client.testConnection()

        XCTAssertEqual(paths, ["/api/v1/printer_profiles"])
    }

    private func makeClient(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        makeClient(token: "  stale-token  ", handler: handler)
    }

    private func makeClient(
        token: String?,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(baseURL: URL(string: "http://example.com")!, token: token, session: session)
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
          "printer_profile": {
            "id": 7,
            "printer_make_model": "Epson SC700",
            "paper_type": "Matte",
            "ink_type": "Pigment"
          },
          "colors": [
            {
              "id": 123,
              "name": "Red 12",
              "hex": "#C64A35",
              "rgb": {"r": 198, "g": 74, "b": 53},
              "palette_id": 5,
              "palette_name": "Default",
              "sort_order": 12,
              "responses": {
                "red": {"brightness": 0.87, "source": "measurement"},
                "lps": {"brightness": 0.52, "source": "response", "apparent_brightness": 5}
              }
            }
          ]
        }
        """.data(using: .utf8)!
    }

    private func colorsResponseWithoutProfile() -> Data {
        """
        {
          "colors": [
            {"id": 9, "hex": "#112233", "rgb": {"r": 17, "g": 34, "b": 51}, "responses": {}}
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
