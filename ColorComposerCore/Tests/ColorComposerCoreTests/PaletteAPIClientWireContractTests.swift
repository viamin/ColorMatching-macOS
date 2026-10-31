import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Pins the wire contract of `PaletteAPIClient` against `/api/v1`.
///
/// When `PaletteAPIClient` is migrated onto the generated OpenAPI client (#39),
/// these tests must keep passing unchanged: the generated client (or its
/// wrapper) has to preserve request shape (paths, query parameter names,
/// headers, bearer-token normalization), response-envelope decoding, and the
/// `PaletteAPIError` mapping. Together with `PaletteAPIClientTests`,
/// `APIDecodingTests`, and `ProfileColorCacheTests` they form the
/// "behavior preserved" gate for the migration.
final class PaletteAPIClientWireContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        WireStubURLProtocol.handler = nil
    }

    // MARK: - GET /api/v1/colors

    func testFetchColorsSendsExpectedRequestShapeAndDecodesEnvelope() async throws {
        let lock = NSLock()
        var seen: [URLRequest] = []
        let client = makeClient { request in
            lock.lock()
            seen.append(request)
            lock.unlock()
            return (
                .init(statusCode: 200, url: request.url!),
                Self.colorsEnvelope
            )
        }

        let (colors, profile) = try await client.fetchColors(printerProfileID: 3)

        let request = try XCTUnwrap(seen.first)
        XCTAssertEqual(request.httpMethod ?? "GET", "GET")
        XCTAssertEqual(request.url?.path, "/api/v1/colors")
        XCTAssertEqual(
            request.url?.query?.split(separator: "&").sorted(),
            ["printer_profile_id=3"],
            "The generated client must keep the printer_profile_id query parameter"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"), "Bearer tok",
            "The bearer token must be trimmed before the request leaves the client"
        )

        XCTAssertEqual(colors.count, 1)
        XCTAssertEqual(colors.first?.id, 123)
        XCTAssertEqual(colors.first?.hex, "#C64A35")
        XCTAssertEqual(colors.first?.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(colors.first?.responses["lps"]?.brightness, 0.52)
        XCTAssertEqual(profile?.id, 1)
        XCTAssertEqual(profile?.printerMakeModel, "Epson")
        XCTAssertEqual(profile?.paperType, "Matte")
        XCTAssertEqual(profile?.inkType, "Dye")
    }

    func testFetchColorsToleratesAbsentPrinterProfileInEnvelope() async throws {
        let client = makeClient { request in
            (
                .init(statusCode: 200, url: request.url!),
                #"{"colors":[{"id":9,"hex":"#010203","rgb":{"r":1,"g":2,"b":3},"responses":{}}]}"#.data(using: .utf8)!
            )
        }

        let (colors, profile) = try await client.fetchColors(printerProfileID: 42)
        XCTAssertEqual(colors.first?.id, 9)
        XCTAssertNil(profile, "printer_profile is optional in the /api/v1/colors envelope")
    }

    func testFetchColorsMaps401ToUnauthorized() async {
        let client = makeClient { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await Self.assertAsyncThrows {
            try await client.fetchColors(printerProfileID: 1)
        } onError: { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testFetchColorsMapsMalformedBodyToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await Self.assertAsyncThrows {
            try await client.fetchColors(printerProfileID: 1)
        } onError: { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - GET /api/v1/printer_profiles

    func testFetchPrinterProfilesMaps500ToBadStatus() async {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
            return (.init(statusCode: 500, url: request.url!), Data())
        }

        await Self.assertAsyncThrows {
            try await client.fetchPrinterProfiles()
        } onError: { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    func testFetchPrinterProfilesDecodesProfileListInOrder() async throws {
        let client = makeClient { request in
            (
                .init(statusCode: 200, url: request.url!),
                #"{"printer_profiles":[{"id":2,"printer_make_model":"Canon","paper_type":"Glossy","ink_type":null},{"id":1,"printer_make_model":"Epson","paper_type":"Matte","ink_type":"Pigment"}]}"#.data(using: .utf8)!
            )
        }

        let profiles = try await client.fetchPrinterProfiles()
        XCTAssertEqual(profiles.map(\.id), [2, 1], "Server order must be preserved")
        XCTAssertNil(profiles.first?.inkType)
        XCTAssertEqual(profiles.last?.inkType, "Pigment")
    }

    // MARK: - Connection test

    func testTestConnectionAcceptsAny2xx() async throws {
        let client = makeClient { request in
            (.init(statusCode: 204, url: request.url!), Data())
        }

        try await client.testConnection()
    }

    // MARK: - Helpers

    private func makeClient(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        WireStubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WireStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(
            baseURL: URL(string: "http://example.com")!,
            token: "  tok  ",
            session: session
        )
    }

    private static let colorsEnvelope = """
    {
      "printer_profile": {
        "id": 1, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"
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

    private static func assertAsyncThrows<T>(
        _ expression: @autoclosure () async throws -> T,
        onError assertions: (Error) -> Void,
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

private final class WireStubURLProtocol: URLProtocol, @unchecked Sendable {
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
