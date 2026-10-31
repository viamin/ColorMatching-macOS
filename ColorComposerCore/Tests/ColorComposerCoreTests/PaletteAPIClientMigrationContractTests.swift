import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Characterization tests for the wire contract `PaletteAPIClient` holds
/// with `color_matching` `/api/v1` (issue #39). These pin request shapes,
/// auth, error mapping, and envelope decoding exactly as they work today,
/// so the migration to the generated OpenAPI client (or a wrapper around
/// it) keeps every observable behavior green — including what feeds the
/// disk cache and offline fallback.
final class PaletteAPIClientMigrationContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MigrationContractMockURLProtocol.handler = nil
    }

    // MARK: - Request shapes

    func testPrinterProfilesRequestsV1EndpointWithJSONAcceptAndBearer() async throws {
        let requests = try await captureRequests { client in
            _ = try await client.fetchPrinterProfiles()
        }

        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://api.example.com/api/v1/printer_profiles")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
    }

    func testColorsRequestsV1EndpointWithPrinterProfileIDQuery() async throws {
        let requests = try await captureRequests { client in
            _ = try await client.fetchColors(printerProfileID: 7)
        }

        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://api.example.com/api/v1/colors?printer_profile_id=7")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
    }

    func testTestConnectionPingsThePrinterProfilesEndpoint() async throws {
        let requests = try await captureRequests { client in
            try await client.testConnection()
        }

        XCTAssertEqual(try XCTUnwrap(requests.first).url?.absoluteString, "http://api.example.com/api/v1/printer_profiles")
    }

    // MARK: - Response decoding

    func testColorsDecodesEnvelopeIncludingEmbeddedProfileForCacheFallback() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), colorsResponse())
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        let color = try XCTUnwrap(fetched.colors.first)
        XCTAssertEqual(color.id, 123)
        XCTAssertEqual(color.name, "Sienna")
        XCTAssertEqual(color.hex, "#A0522D")
        XCTAssertEqual(color.rgb?.r, 160)
        XCTAssertEqual(color.paletteId, 5)
        XCTAssertEqual(color.sortOrder, 0)
        XCTAssertEqual(color.responses["white"]?.brightness, 0.375)
        XCTAssertEqual(color.responses["lps"]?.brightness, 0.125)

        // The embedded profile is what `CachedProfileColors.profile` stores;
        // the offline picker's cached-profile fallback depends on it decoding.
        let profile = try XCTUnwrap(fetched.profile)
        XCTAssertEqual(profile.id, 7)
        XCTAssertEqual(profile.printerMakeModel, "Epson P900")
        XCTAssertEqual(profile.paperType, "Matte")
        XCTAssertEqual(profile.inkType, "Pigment")

        let domain = try XCTUnwrap(color.toDomain())
        XCTAssertEqual(domain.brightness(for: .white), 0.375)
        XCTAssertNil(domain.brightness(for: .red), "unmeasured conditions must stay absent")
    }

    func testPrinterProfilesDecodesEnvelope() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), printerProfilesResponse())
        }

        let profiles = try await client.fetchPrinterProfiles()
        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.id, 3)
        XCTAssertEqual(profile.displayName, "Canon P900 · Gloss · Dye")
    }

    // MARK: - Error mapping (re-auth vs. status vs. malformed)

    func testColorsMaps401ToUnauthorizedForReAuthFlow() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testColorsMapsNon2xxToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testColorsMapsUndecodableBodyToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - Helpers

    private func makeClient(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MigrationContractMockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MigrationContractMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(
            baseURL: URL(string: "http://api.example.com")!,
            token: "token-123",
            session: session
        )
    }

    /// Runs `body` against a mock-backed client and returns every request it
    /// issued, so shape assertions see exactly what the migration must keep
    /// producing.
    private func captureRequests(
        _ body: (PaletteAPIClient) async throws -> Void
    ) async throws -> [URLRequest] {
        let lock = NSLock()
        var requests: [URLRequest] = []
        let client = makeClient { request in
            lock.lock()
            requests.append(request)
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), #"{"printer_profiles":[],"colors":[]}"#.data(using: .utf8)!)
        }
        try await body(client)
        return requests
    }

    private func colorsResponse() -> Data {
        """
        {
          "printer_profile": {
            "id": 7,
            "printer_make_model": "Epson P900",
            "paper_type": "Matte",
            "ink_type": "Pigment"
          },
          "colors": [
            {
              "id": 123,
              "name": "Sienna",
              "hex": "#A0522D",
              "rgb": {"r": 160, "g": 82, "b": 45},
              "palette_id": 5,
              "palette_name": "Default",
              "sort_order": 0,
              "responses": {
                "white": {"brightness": 0.375},
                "lps": {"brightness": 0.125}
              }
            }
          ]
        }
        """.data(using: .utf8)!
    }

    private func printerProfilesResponse() -> Data {
        """
        {
          "printer_profiles": [
            {
              "id": 3,
              "printer_make_model": "Canon P900",
              "paper_type": "Gloss",
              "ink_type": "Dye"
            }
          ]
        }
        """.data(using: .utf8)!
    }
}

private final class MigrationContractMockURLProtocol: URLProtocol, @unchecked Sendable {
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
