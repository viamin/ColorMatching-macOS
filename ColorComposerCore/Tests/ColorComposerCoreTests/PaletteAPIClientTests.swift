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

    // MARK: - /api/v1 wire contract (must survive the generated-client migration)

    func testFetchColorsSendsPrinterProfileIDQueryAndDecodesEnvelope() async throws {
        let lock = NSLock()
        var urls: [String] = []
        var accepts: [String?] = []
        let client = makeClient { request in
            lock.lock()
            urls.append(request.url?.absoluteString ?? "")
            accepts.append(request.value(forHTTPHeaderField: "Accept"))
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), colorsEnvelope())
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(urls, ["http://example.com/api/v1/colors?printer_profile_id=7"])
        XCTAssertEqual(accepts, ["application/json"])
        XCTAssertEqual(fetched.profile?.id, 7)

        XCTAssertEqual(fetched.colors.count, 2)
        let sienna = try XCTUnwrap(fetched.colors.first)
        XCTAssertEqual(sienna.hex, "#A0522D")
        XCTAssertEqual(sienna.rgb?.r, 160)
        XCTAssertEqual(sienna.paletteName, "Earth")
        XCTAssertEqual(sienna.responses["red"]?.brightness, 0.5)
        XCTAssertEqual(sienna.responses["lps"]?.apparentBrightness, 1)
        // Unknown light-source keys stay in the wire map but drop in domain conversion.
        XCTAssertNotNil(sienna.responses["ultraviolet"])
        let domain = try XCTUnwrap(sienna.toDomain())
        XCTAssertEqual(domain.responses.count, 2)
    }

    func testFetchColorsThrowsUnauthorizedOn401() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testFetchColorsThrowsBadStatusOn500() async {
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

    func testFetchPrinterProfilesDecodesNullableOptionalFields() async throws {
        let client = makeClient { request in
            (
                .init(statusCode: 200, url: request.url!),
                Data(#"{"printer_profiles":[{"id":3,"printer_make_model":null,"paper_type":null,"ink_type":null}]}"#.utf8)
            )
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.id, 3)
        XCTAssertEqual(profiles.first?.displayName, "Profile #3")
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

    private func colorsEnvelope() -> Data {
        """
        {
          "colors": [
            {
              "id": 9,
              "name": "Sienna",
              "hex": "#A0522D",
              "rgb": {"r": 160, "g": 82, "b": 45},
              "palette_id": 2,
              "palette_name": "Earth",
              "sort_order": 4,
              "responses": {
                "red": {"brightness": 0.5},
                "lps": {"brightness": 0.125, "source": "response", "apparent_brightness": 1},
                "ultraviolet": {"brightness": 0.9}
              }
            },
            {
              "id": 10,
              "hex": "#123456",
              "responses": {}
            }
          ],
          "printer_profile": {
            "id": 7,
            "printer_make_model": "Epson",
            "paper_type": "Matte",
            "ink_type": "Pigment"
          }
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
