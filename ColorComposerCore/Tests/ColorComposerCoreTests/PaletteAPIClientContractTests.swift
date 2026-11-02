import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Behavior-preservation net for the generated-OpenAPI-client migration
/// (issue #39): pins the exact requests `PaletteAPIClient` issues and the
/// error/envelope decoding callers rely on, and cross-checks every issued
/// request against the routes declared in the committed OpenAPI document
/// (`Fixtures/openapi-v1.json`).
///
/// These must stay green unchanged when the client is regenerated from the
/// spec — including the disk-cache/offline-stale surface, which sits downstream
/// of these decoded DTOs (see `ProfileColorCacheTests`).
final class PaletteAPIClientContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        SpecMockURLProtocol.handler = nil
    }

    // MARK: - Requests match the committed spec

    func testFetchColorsRequestsDeclaredColorsRoute() async throws {
        let (client, requests) = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsEnvelope())
        }

        let (colors, profile) = try await client.fetchColors(printerProfileID: 42)

        let request = try XCTUnwrap(requests.all.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/api/v1/colors?printer_profile_id=42")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-value")
        XCTAssertTrue(try specDeclaresGET("/api/v1/colors"), "client must only call routes the committed OpenAPI document declares")

        XCTAssertEqual(profile?.id, 42)
        XCTAssertEqual(colors.count, 1)
        XCTAssertEqual(colors.first?.id, 9)
        XCTAssertEqual(colors.first?.responses["red"]?.brightness, 0.5)
        XCTAssertEqual(colors.first?.responses["lps"]?.brightness, 0.25)
    }

    func testFetchPrinterProfilesRequestsDeclaredRoute() async throws {
        let (client, requests) = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.printerProfilesEnvelope())
        }

        let profiles = try await client.fetchPrinterProfiles()

        let request = try XCTUnwrap(requests.all.first)
        XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
        XCTAssertTrue(try specDeclaresGET("/api/v1/printer_profiles"), "client must only call routes the committed OpenAPI document declares")

        XCTAssertEqual(profiles.first?.id, 7)
        XCTAssertEqual(profiles.first?.paperType, "Matte")
    }

    func testTestConnectionProbesPrinterProfilesRoute() async throws {
        let (client, requests) = makeClient { request in
            (.init(statusCode: 204, url: request.url!), Data())
        }

        try await client.testConnection()

        let request = try XCTUnwrap(requests.all.first)
        XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
        XCTAssertTrue(try specDeclaresGET("/api/v1/printer_profiles"))
    }

    // MARK: - Error mapping preserved

    func testFetchColorsMapsUnauthorized() async {
        let (client, _) = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await assertAsyncThrows(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testFetchColorsMapsBadStatus() async {
        let (client, _) = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await assertAsyncThrows(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testFetchColorsMapsMalformedBody() async {
        let (client, _) = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("{".utf8))
        }

        await assertAsyncThrows(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - Fixtures

    private func makeClient(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> (PaletteAPIClient, SharedRequests) {
        let requests = SharedRequests()
        SpecMockURLProtocol.handler = { request in
            requests.record(request)
            return try handler(request)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpecMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = PaletteAPIClient(
            baseURL: URL(string: "https://api.example.com")!,
            token: "  token-value  ",
            session: session
        )
        return (client, requests)
    }

    private final class SharedRequests: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [URLRequest] = []

        func record(_ request: URLRequest) {
            lock.lock()
            values.append(request)
            lock.unlock()
        }

        var all: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private static func colorsEnvelope() -> Data {
        """
        {
          "printer_profile": {"id": 42, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"},
          "colors": [
            {
              "id": 9, "name": "Sienna", "hex": "#A0522D",
              "rgb": {"r": 160, "g": 82, "b": 45},
              "palette_id": 2, "palette_name": "Earth", "sort_order": 3,
              "responses": {
                "red": {"brightness": 0.5},
                "lps": {"brightness": 0.25}
              }
            }
          ]
        }
        """.data(using: .utf8)!
    }

    private static func printerProfilesEnvelope() -> Data {
        """
        {"printer_profiles": [{"id": 7, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"}]}
        """.data(using: .utf8)!
    }

    private func specDeclaresGET(_ path: String) throws -> Bool {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("openapi-v1.json")
        let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        let paths = try XCTUnwrap(document["paths"] as? [String: Any])
        return (paths[path] as? [String: Any])?["get"] != nil
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
}

private final class SpecMockURLProtocol: URLProtocol, @unchecked Sendable {
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
