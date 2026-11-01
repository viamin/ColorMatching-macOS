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

    private func makeClient(
        token: String? = "  stale-token  ",
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
            "printer_make_model": "Epson SC-P5000",
            "paper_type": "Matte",
            "ink_type": "Pigment"
          },
          "colors": [
            {
              "id": 123,
              "name": "Sienna",
              "hex": "#A0522D",
              "rgb": { "r": 160, "g": 82, "b": 45 },
              "palette_id": 5,
              "palette_name": "Earth",
              "sort_order": 2,
              "responses": {
                "red": { "brightness": 0.5, "source": "measurement" },
                "lps": { "brightness": 0.125 }
              }
            }
          ]
        }
        """.data(using: .utf8)!
    }

    // MARK: - Wire contract pinned for the generated-client migration (#39)

    func testFetchColorsSendsPrinterProfileIDQueryAndDecodesEnvelope() async throws {
        let body = colorsResponse()
        let client = makeClient(token: nil) { request in
            XCTAssertEqual(request.url?.path, "/api/v1/colors")
            XCTAssertEqual(request.url?.query, "printer_profile_id=7")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), body)
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(fetched.colors.map(\.id), [123])
        XCTAssertEqual(fetched.colors.first?.hex, "#A0522D")
        XCTAssertEqual(fetched.colors.first?.rgb?.r, 160)
        XCTAssertEqual(fetched.colors.first?.responses["red"]?.brightness, 0.5)
        XCTAssertNil(fetched.colors.first?.responses["white"])
        XCTAssertEqual(fetched.profile?.id, 7)
        XCTAssertEqual(fetched.profile?.paperType, "Matte")
    }

    func testFetchPrinterProfilesDecodesSnakeCaseEnvelope() async throws {
        let body = printerProfilesResponse()
        let client = makeClient(token: nil) { request in
            XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
            return (.init(statusCode: 200, url: request.url!), body)
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.id, 1)
        XCTAssertEqual(profiles.first?.printerMakeModel, "Example Printer")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
        XCTAssertEqual(profiles.first?.inkType, "Pigment")
    }

    func testFetchColorsMapsServerErrorToBadStatus() async {
        let client = makeClient(token: nil) { request in
            (.init(statusCode: 500, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    func testFetchColorsMapsUndecodableBodyToMalformedResponse() async {
        let client = makeClient(token: nil) { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testOmitsAuthorizationHeaderWhenNoTokenConfigured() async throws {
        let body = printerProfilesResponse()
        let lock = NSLock()
        var authHeaders: [String?] = []
        let client = makeClient(token: nil) { request in
            lock.lock()
            authHeaders.append(request.value(forHTTPHeaderField: "Authorization"))
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), body)
        }

        _ = try await client.fetchPrinterProfiles()

        XCTAssertEqual(authHeaders, [nil])
    }

    func testTestConnectionSucceedsOn2xx() async throws {
        let client = makeClient(token: nil) { request in
            XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
            return (.init(statusCode: 204, url: request.url!), Data())
        }

        try await client.testConnection()
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
