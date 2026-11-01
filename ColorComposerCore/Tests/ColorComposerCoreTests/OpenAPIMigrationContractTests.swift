import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Pins the `/api/v1` wire contract consumed by `PaletteAPIClient` — endpoint
/// paths, query parameters, headers, snake_case envelopes, and status-code →
/// error mapping. The generated OpenAPI client migration (issue #39) must keep
/// every one of these observable behaviors intact; these tests define the
/// "unchanged" that the migration is measured against.
final class OpenAPIMigrationContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        ContractMockURLProtocol.handler = nil
    }

    // MARK: - GET /api/v1/colors

    func testFetchColorsBuildsVersionedRequestWithProfileQueryAndHeaders() async throws {
        let lock = NSLock()
        var captured: [URLRequest] = []
        let client = makeClient { request in
            lock.lock()
            captured.append(request)
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), colorsResponseData())
        }

        _ = try await client.fetchColors(printerProfileID: 7)

        let request = try XCTUnwrap(captured.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.url?.absoluteString,
            "http://example.com/api/v1/colors?printer_profile_id=7"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer stale-token")
    }

    func testFetchColorsDecodesEnvelopeWithSnakeCaseKeys() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), colorsResponseData())
        }

        let (colors, profile) = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(colors.count, 1)
        XCTAssertEqual(colors.first?.id, 123)
        XCTAssertEqual(colors.first?.name, "Red 12")
        XCTAssertEqual(colors.first?.rgb?.r, 198)
        XCTAssertEqual(colors.first?.paletteId, 5)
        XCTAssertEqual(colors.first?.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(profile?.id, 7)
        XCTAssertEqual(profile?.paperType, "Glossy")
    }

    func testFetchColorsMaps401ToUnauthorized() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testFetchColorsMapsNon2xxToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
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

    // MARK: - GET /api/v1/printer_profiles

    func testFetchPrinterProfilesMapsNon2xxToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 500, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    // MARK: - testConnection

    func testTestConnectionAcceptsAny2xxEvenWithAnEmptyBody() async {
        let client = makeClient { request in
            (.init(statusCode: 204, url: request.url!), Data())
        }

        await XCTAssertNoThrowAsync(try await client.testConnection())
    }

    // MARK: - Helpers

    private func makeClient(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        ContractMockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContractMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(baseURL: URL(string: "http://example.com")!, token: "  stale-token  ", session: session)
    }

    /// Wire-shaped `/api/v1/colors` envelope exactly as the server emits it
    /// (snake_case keys, optional profile metadata).
    private func colorsResponseData() -> Data {
        """
        {
          "printer_profile": {
            "id": 7, "printer_make_model": "Canon", "paper_type": "Glossy", "ink_type": "Pigment"
          },
          "colors": [
            {
              "id": 123, "name": "Red 12", "hex": "#C64A35",
              "rgb": {"r": 198, "g": 74, "b": 53},
              "palette_id": 5, "palette_name": "Default", "sort_order": 12,
              "responses": {
                "red": {"brightness": 0.87}
              }
            }
          ]
        }
        """.data(using: .utf8)!
    }
}

private final class ContractMockURLProtocol: URLProtocol, @unchecked Sendable {
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

private func XCTAssertNoThrowAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
    } catch {
        XCTFail("Expected no error, but received \(error)", file: file, line: line)
    }
}
