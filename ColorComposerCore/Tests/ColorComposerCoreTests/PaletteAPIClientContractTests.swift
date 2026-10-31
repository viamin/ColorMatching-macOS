import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire-contract coverage for `PaletteAPIClient`'s `/api/v1` surface.
///
/// The generated OpenAPI client migration (issue #39) swaps how requests are
/// issued and responses are decoded; these tests pin the externally observable
/// contract so the migration cannot silently change it: endpoint paths, the
/// `printer_profile_id` query, `Accept`/`Authorization` headers, status-code
/// error mapping, snake_case decoding, absent-not-zero responses, and the
/// hex fallback for colors without explicit RGB. Disk-cache and offline-stale
/// behavior on top of this client stays guarded by `ProfileColorCacheTests`.
final class PaletteAPIClientContractTests: XCTestCase {
    private let baseURL = URL(string: "http://api.example.com")!

    override func tearDown() {
        super.tearDown()
        ContractMockURLProtocol.handler = nil
    }

    // MARK: - Endpoints and headers

    func testFetchColorsRequestsVersionedColorsEndpointWithProfileQuery() async throws {
        let lock = NSLock()
        var captured: URLRequest?
        let client = makeClient { request in
            lock.lock()
            captured = request
            lock.unlock()
            return (HTTPURLResponse(statusCode: 200, url: request.url!), Self.colorsEnvelope())
        }

        let (colors, profile) = try await client.fetchColors(printerProfileID: 7)

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.absoluteString, "http://api.example.com/api/v1/colors?printer_profile_id=7")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertEqual(colors.count, 2)
        XCTAssertEqual(profile?.id, 7)
    }

    func testFetchPrinterProfilesRequestsVersionedProfilesEndpointAndDecodesSnakeCase() async throws {
        let lock = NSLock()
        var captured: URLRequest?
        let client = makeClient { request in
            lock.lock()
            captured = request
            lock.unlock()
            return (HTTPURLResponse(statusCode: 200, url: request.url!), Self.printerProfilesEnvelope())
        }

        let profiles = try await client.fetchPrinterProfiles()

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.absoluteString, "http://api.example.com/api/v1/printer_profiles")
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.id, 7)
        XCTAssertEqual(profiles.first?.printerMakeModel, "Epson SC-P5000")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
        XCTAssertEqual(profiles.first?.inkType, "Pigment")
    }

    func testMissingTokenOmitsAuthorizationHeader() async throws {
        let lock = NSLock()
        var captured: URLRequest?
        let client = makeClient(token: nil) { request in
            lock.lock()
            captured = request
            lock.unlock()
            return (HTTPURLResponse(statusCode: 200, url: request.url!), Self.printerProfilesEnvelope())
        }

        _ = try await client.fetchPrinterProfiles()

        let request = try XCTUnwrap(captured)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - Payload semantics

    func testFetchColorsDecodesEnvelopeAndKeepsMissingResponsesAbsentNotZero() async throws {
        let client = makeClient { request in
            (HTTPURLResponse(statusCode: 200, url: request.url!), Self.colorsEnvelope())
        }

        let (colors, profile) = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(profile?.id, 7)
        XCTAssertEqual(colors.count, 2)

        let measured = try XCTUnwrap(colors.first).toDomain()
        XCTAssertEqual(measured.id, 11)
        XCTAssertEqual(measured.brightness(for: .red), 0.87)
        XCTAssertEqual(measured.brightness(for: .lps), 0.52)
        XCTAssertNil(measured.brightness(for: .green), "unmeasured conditions are absent, never zero")
        XCTAssertNil(measured.brightness(for: .white))

        let unmeasured = try XCTUnwrap(colors.last).toDomain()
        XCTAssertNil(unmeasured.brightness(for: .red))
        XCTAssertNil(unmeasured.brightness(for: .lps))
        XCTAssertEqual(unmeasured.rgb, RGBColor(hex: "#00FF80"), "rgb falls back to hex when the field is omitted")
    }

    // MARK: - Status mapping

    func testFetchColorsMapsServiceUnavailableToBadStatus() async {
        let client = makeClient { request in
            (HTTPURLResponse(statusCode: 503, url: request.url!), Data("[]".utf8))
        }

        await assertThrowsPaletteAPIError(try await client.fetchColors(printerProfileID: 7), expected: .badStatus(503))
    }

    func testFetchColorsMapsMalformedBodyToMalformedResponse() async {
        let client = makeClient { request in
            (HTTPURLResponse(statusCode: 200, url: request.url!), Data("{not json".utf8))
        }

        await assertThrowsPaletteAPIError(try await client.fetchColors(printerProfileID: 7), expected: .malformedResponse)
    }

    func testTestConnectionSucceedsOn2xx() async throws {
        let client = makeClient { request in
            (HTTPURLResponse(statusCode: 200, url: request.url!), Data())
        }

        try await client.testConnection()
    }

    func testTestConnectionMapsUnauthorized() async {
        let client = makeClient { request in
            (HTTPURLResponse(statusCode: 401, url: request.url!), Data())
        }

        await assertThrowsPaletteAPIError(try await client.testConnection(), expected: .unauthorized)
    }

    // MARK: - Helpers

    private func makeClient(
        token: String? = "  secret-token  ",
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        ContractMockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContractMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(baseURL: baseURL, token: token, session: session)
    }

    private func assertThrowsPaletteAPIError<T: Sendable>(
        _ expression: @autoclosure () async throws -> T,
        expected: PaletteAPIError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected PaletteAPIError.\(expected) to be thrown", file: file, line: line)
        } catch let error as PaletteAPIError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected PaletteAPIError.\(expected) but received \(error)", file: file, line: line)
        }
    }

    private static func colorsEnvelope() -> Data {
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
              "id": 11,
              "name": "Red 032",
              "hex": "#C62828",
              "rgb": {"r": 198, "g": 40, "b": 40},
              "palette_id": 2,
              "palette_name": "Standard",
              "sort_order": 1,
              "responses": {
                "red": {"brightness": 0.87, "source": "measurement"},
                "lps": {"brightness": 0.52, "source": "response", "apparent_brightness": 5}
              }
            },
            {
              "id": 12,
              "name": "Unmeasured Swatch",
              "hex": "#00FF80",
              "responses": {}
            }
          ]
        }
        """.data(using: .utf8)!
    }

    private static func printerProfilesEnvelope() -> Data {
        """
        {
          "printer_profiles": [
            {
              "id": 7,
              "printer_make_model": "Epson SC-P5000",
              "paper_type": "Matte",
              "ink_type": "Pigment"
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
