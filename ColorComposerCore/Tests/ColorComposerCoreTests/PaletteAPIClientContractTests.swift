import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Characterization of the `/api/v1` wire contract `PaletteAPIClient` relies
/// on, pinned against the OpenAPI document published by `color_matching`
/// (upstream issue #110, served at `GET /api/v1/openapi.json`).
///
/// These tests encode the exact envelopes, snake_case keys, query parameters,
/// headers, and error mapping the app consumes today. The generated
/// OpenAPI-client migration (issue #39) must keep every one of them green —
/// or surface a deliberate shape change here first.
final class PaletteAPIClientContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        ContractMockURLProtocol.handler = nil
    }

    // MARK: - GET /api/v1/printer_profiles

    func testFetchPrinterProfilesPinsRequestShapeAndWireEnvelope() async throws {
        let client = makeClient(token: nil) { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles[0].id, 1)
        XCTAssertEqual(profiles[0].printerMakeModel, "Example Printer")
        XCTAssertEqual(profiles[0].paperType, "Matte")
        XCTAssertEqual(profiles[0].inkType, "Pigment")
        XCTAssertEqual(profiles[1].id, 2)
        XCTAssertEqual(profiles[1].printerMakeModel, "Other Printer")
    }

    // MARK: - GET /api/v1/colors?printer_profile_id=N

    func testFetchColorsPinsRequestShapeAndWireEnvelope() async throws {
        let client = makeClient(token: nil) { request in
            XCTAssertEqual(request.url?.path, "/api/v1/colors")
            let query = request.url?.query ?? ""
            XCTAssertTrue(query.contains("printer_profile_id=7"), "expected the profile id query, got: \(query)")
            return (.init(statusCode: 200, url: request.url!), Self.colorsBody)
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(fetched.colors.count, 2)
        XCTAssertEqual(fetched.profile?.id, 7)
        XCTAssertEqual(fetched.profile?.paperType, "Matte")

        let cyan = fetched.colors[0]
        XCTAssertEqual(cyan.id, 10)
        XCTAssertEqual(cyan.name, "Process Cyan")
        XCTAssertEqual(cyan.hex, "#00FFFF")
        XCTAssertEqual(cyan.rgb?.r, 0)
        XCTAssertEqual(cyan.rgb?.g, 255)
        XCTAssertEqual(cyan.rgb?.b, 255)
        XCTAssertEqual(cyan.paletteId, 2)
        XCTAssertEqual(cyan.paletteName, "Base palette")
        XCTAssertEqual(cyan.sortOrder, 1)
        XCTAssertEqual(cyan.responses["red"]?.brightness, 0.25, accuracy: 1e-12)
        XCTAssertEqual(cyan.responses["lps"]?.source, "response")
        XCTAssertEqual(cyan.responses["lps"]?.apparentBrightness, 3)
    }

    /// A color with no measured responses decodes with an empty response map:
    /// "unmeasured" stays distinguishable from "measured as zero", which the
    /// solver's exclusion policy (and the parity corpus) depends on.
    func testFetchColorsKeepsResponselessColorsDecodable() async throws {
        let client = makeClient(token: nil) { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsBody)
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        let unmeasured = try XCTUnwrap(fetched.colors.first { $0.id == 11 })
        XCTAssertTrue(unmeasured.responses.isEmpty)
    }

    /// Domain conversion must keep unknown light-source keys out of the
    /// solver's domain (the corpus's `unknown-weight-ignored` scenario is the
    /// matching policy on the weights side).
    func testFetchedColorDomainConversionDropsUnknownResponseKeys() async throws {
        let client = makeClient(token: nil) { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsBodyWithUnknownKey)
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        let domain = try XCTUnwrap(fetched.colors[0].toDomain())
        let red = try XCTUnwrap(domain.brightness(for: .red))
        XCTAssertEqual(red, 0.25, accuracy: 1e-12)
        XCTAssertNil(domain.brightness(for: .white))
        XCTAssertEqual(Set(domain.responses.keys), [.red])
    }

    // MARK: - Error contract

    func testUnauthorizedMapsDistinctlyFromOtherBadStatuses() async {
        await assertThrowsPaletteAPIError(status: 401, expected: .unauthorized)
        await assertThrowsPaletteAPIError(status: 403, expected: .badStatus(403))
        await assertThrowsPaletteAPIError(status: 500, expected: .badStatus(500))
    }

    func testUndecodableBodyMapsToMalformedResponse() async {
        let client = makeClient(token: nil) { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - Authorization contract

    func testBlankTokenOmitsAuthorizationHeader() async throws {
        let client = makeClient(token: "   ") { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        _ = try await client.fetchPrinterProfiles()
    }

    // MARK: - Helpers

    private func makeClient(
        token: String?,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        ContractMockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContractMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(baseURL: URL(string: "http://example.com")!, token: token, session: session)
    }

    private func assertThrowsPaletteAPIError(status: Int, expected: PaletteAPIError) async {
        let client = makeClient(token: nil) { request in
            (.init(statusCode: status, url: request.url!), Data())
        }
        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, expected)
        }
    }

    private static let printerProfilesBody: Data = """
    {
      "printer_profiles": [
        {
          "id": 1,
          "printer_make_model": "Example Printer",
          "paper_type": "Matte",
          "ink_type": "Pigment"
        },
        {
          "id": 2,
          "printer_make_model": "Other Printer",
          "paper_type": "Glossy",
          "ink_type": "Dye"
        }
      ]
    }
    """.data(using: .utf8)!

    private static let colorsBody: Data = """
    {
      "printer_profile": {
        "id": 7,
        "printer_make_model": "Example Printer",
        "paper_type": "Matte",
        "ink_type": "Pigment"
      },
      "colors": [
        {
          "id": 10,
          "name": "Process Cyan",
          "hex": "#00FFFF",
          "rgb": { "r": 0, "g": 255, "b": 255 },
          "palette_id": 2,
          "palette_name": "Base palette",
          "sort_order": 1,
          "responses": {
            "red": { "brightness": 0.25 },
            "lps": { "brightness": 0.3, "source": "response", "apparent_brightness": 3 }
          }
        },
        {
          "id": 11,
          "name": "Unmeasured Swatch",
          "hex": "#123456",
          "palette_id": 2,
          "sort_order": 2,
          "responses": {}
        }
      ]
    }
    """.data(using: .utf8)!

    private static let colorsBodyWithUnknownKey: Data = """
    {
      "printer_profile": {
        "id": 7,
        "printer_make_model": "Example Printer",
        "paper_type": "Matte",
        "ink_type": "Pigment"
      },
      "colors": [
        {
          "id": 10,
          "name": "Process Cyan",
          "hex": "#00FFFF",
          "responses": {
            "red": { "brightness": 0.25 },
            "ultraviolet": { "brightness": 0.9 }
          }
        }
      ]
    }
    """.data(using: .utf8)!
}

private final class ContractMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = handler(request)
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
