import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire/transport contract for `PaletteAPIClient` against the `color_matching`
/// `/api/v1` API. These tests are the acceptance gate for the generated
/// OpenAPI-client migration (issue #39): migrating `PaletteAPIClient` onto a
/// swift-openapi-runtime client (directly or wrapped) must keep every
/// observable behavior below unchanged — endpoint URLs, query parameters,
/// headers, envelope decoding, and the `PaletteAPIError` mapping — so the
/// app's disk-cache/offline-stale fallback behavior (ColorCatalog +
/// ProfileColorCache) is untouched.
final class PaletteAPIClientContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        StubURLProtocol.handler = nil
    }

    // MARK: - GET /api/v1/colors

    func testFetchColorsBuildsExpectedRequestAndDecodesEnvelope() async throws {
        let recorder = RequestRecorder()
        let client = makeClient(token: "secret-token") { request in
            recorder.record(request)
            return (.init(statusCode: 200, url: request.url!), Self.colorsPayload)
        }

        let fetched = try await client.fetchColors(printerProfileID: 42)

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "http://example.com/api/v1/colors?printer_profile_id=42")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")

        XCTAssertEqual(fetched.colors.count, 1)
        XCTAssertEqual(fetched.colors.first?.id, 123)
        XCTAssertEqual(fetched.colors.first?.hex, "#C64A35")
        XCTAssertEqual(fetched.colors.first?.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(fetched.profile?.id, 1)
        XCTAssertEqual(fetched.profile?.paperType, "Matte")
    }

    func testFetchColorsMapsHTTP401ToUnauthorized() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await assertThrowsPaletteAPIError(try await client.fetchColors(printerProfileID: 1), .unauthorized)
    }

    func testFetchColorsMapsNon2xxToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await assertThrowsPaletteAPIError(try await client.fetchColors(printerProfileID: 1), .badStatus(503))
    }

    func testFetchColorsMapsUndecodableBodyToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await assertThrowsPaletteAPIError(try await client.fetchColors(printerProfileID: 1), .malformedResponse)
    }

    // MARK: - GET /api/v1/printer_profiles

    func testFetchPrinterProfilesBuildsExpectedRequestAndDecodes() async throws {
        let recorder = RequestRecorder()
        let client = makeClient(token: nil) { request in
            recorder.record(request)
            return (.init(statusCode: 200, url: request.url!), Self.profilesPayload)
        }

        let profiles = try await client.fetchPrinterProfiles()

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "http://example.com/api/v1/printer_profiles")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.id, 1)
        XCTAssertEqual(profiles.first?.printerMakeModel, "Example Printer")
        XCTAssertEqual(profiles.first?.displayName, "Example Printer · Matte · Pigment")
    }

    // MARK: - Reachability probe

    func testConnectionSucceedsOn2xx() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("[]".utf8))
        }

        await assertNoThrow(try await client.testConnection())
    }

    func testConnectionMaps401ToUnauthorized() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await assertThrowsPaletteAPIError(try await client.testConnection(), .unauthorized)
    }

    // MARK: - Helpers

    /// Lock-guarded request capture for `@Sendable` stub handlers.
    private final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var captured: [URLRequest] = []

        func record(_ request: URLRequest) {
            lock.lock()
            captured.append(request)
            lock.unlock()
        }

        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return captured
        }
    }

    private func makeClient(
        token: String? = nil,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        StubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return PaletteAPIClient(
            baseURL: URL(string: "http://example.com")!,
            token: token,
            session: URLSession(configuration: configuration)
        )
    }

    private func assertThrowsPaletteAPIError<T>(
        _ expression: @autoclosure () async throws -> T,
        _ expected: PaletteAPIError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected \(expected) to be thrown", file: file, line: line)
        } catch let error as PaletteAPIError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected PaletteAPIError \(expected), got \(error)", file: file, line: line)
        }
    }

    private func assertNoThrow<T>(
        _ expression: @autoclosure () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }

    private static let colorsPayload = """
    {
      "printer_profile": {
        "id": 1, "printer_make_model": "Example Printer", "paper_type": "Matte", "ink_type": "Pigment"
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
    """.data(using: .utf8)!

    private static let profilesPayload = """
    {
      "printer_profiles": [
        {"id": 1, "printer_make_model": "Example Printer", "paper_type": "Matte", "ink_type": "Pigment"}
      ]
    }
    """.data(using: .utf8)!
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
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

private extension HTTPURLResponse {
    convenience init(statusCode: Int, url: URL) {
        self.init(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }
}
