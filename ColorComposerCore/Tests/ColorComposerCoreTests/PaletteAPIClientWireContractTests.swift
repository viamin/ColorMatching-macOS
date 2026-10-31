import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire-level contract for `PaletteAPIClient` against the `/api/v1` shapes
/// described by the server's OpenAPI document (viamin/color_matching#110).
///
/// These pin exactly the surface issue #39 requires the generated-client
/// migration to preserve: endpoint paths, the `printer_profile_id` query,
/// bearer-token handling, the snake_case response envelopes, and the error
/// mapping. They pass against the hand-rolled client today and must still
/// pass after `PaletteAPIClient` wraps the swift-openapi-runtime client.
final class PaletteAPIClientWireContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        WireMockURLProtocol.handler = nil
    }

    func testFetchPrinterProfilesDecodesMultipleProfilesFromWirePayload() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesPayload)
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.map(\.id), [1, 7])
        XCTAssertEqual(profiles[1].printerMakeModel, "Canon PRO-1000")
        XCTAssertEqual(profiles[1].paperType, "Fine Art Rag")
        XCTAssertEqual(profiles[1].inkType, "Pigment")
    }

    func testFetchColorsSendsProfileIDQueryAndDecodesEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/colors")
            let query = request.url?.query?.split(separator: "&").map(String.init) ?? []
            XCTAssertTrue(query.contains("printer_profile_id=7"), "expected printer_profile_id=7 in \(query)")
            return (.init(statusCode: 200, url: request.url!), Self.colorsPayload)
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(fetched.profile?.id, 7)
        XCTAssertEqual(fetched.colors.count, 2)
        let red = try XCTUnwrap(fetched.colors.first { $0.id == 123 })
        XCTAssertEqual(red.hex, "#C64A35")
        XCTAssertEqual(red.rgb?.r, 198)
        XCTAssertEqual(red.paletteName, "Default")
        XCTAssertEqual(red.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(red.responses["red"]?.source, "measurement")
        XCTAssertEqual(red.responses["lps"]?.apparentBrightness, 5)
        XCTAssertNil(red.responses["green"], "unmeasured channels are absent, not zero")
    }

    func testFetchColorsMapsMalformedBodyToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await assertThrows(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testServerErrorMapsToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 500, url: request.url!), Data())
        }

        await assertThrows(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    func testOmittedTokenSendsNoAuthorizationHeader() async throws {
        let client = makeClient(token: nil) { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesPayload)
        }

        _ = try await client.fetchPrinterProfiles()
    }

    func testTestConnectionToleratesEmptyBody() async throws {
        let client = makeClient { request in
            (.init(statusCode: 204, url: request.url!), Data())
        }

        try await client.testConnection()
    }

    // MARK: - Fixtures

    private static let printerProfilesPayload = """
    {
      "printer_profiles": [
        {"id": 1, "printer_make_model": "Epson P900", "paper_type": "Matte", "ink_type": "Dye"},
        {"id": 7, "printer_make_model": "Canon PRO-1000", "paper_type": "Fine Art Rag", "ink_type": "Pigment"}
      ]
    }
    """.data(using: .utf8)!

    private static let colorsPayload = """
    {
      "printer_profile": {"id": 7, "printer_make_model": "Canon PRO-1000", "paper_type": "Fine Art Rag", "ink_type": "Pigment"},
      "colors": [
        {
          "id": 123, "name": "Red 12", "hex": "#C64A35",
          "rgb": {"r": 198, "g": 74, "b": 53},
          "palette_id": 5, "palette_name": "Default", "sort_order": 12,
          "responses": {
            "red": {"brightness": 0.87, "source": "measurement", "raw_value": null, "raw_unit": null, "apparent_brightness": null, "measured_at": null, "test_run_id": null},
            "lps": {"brightness": 0.52, "source": "response", "apparent_brightness": 5, "raw_value": null, "raw_unit": null, "measured_at": null, "test_run_id": null}
          }
        },
        {"id": 124, "name": "Blue 3", "hex": "#3564C6", "rgb": {"r": 53, "g": 100, "b": 198}, "palette_id": 5, "palette_name": "Default", "sort_order": 13, "responses": {"blue": {"brightness": 0.9, "source": "response", "apparent_brightness": 9}}}
      ]
    }
    """.data(using: .utf8)!

    private func makeClient(
        token: String? = "secret-token",
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        WireMockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WireMockURLProtocol.self]
        return PaletteAPIClient(
            baseURL: URL(string: "http://example.com")!,
            token: token,
            session: URLSession(configuration: configuration)
        )
    }

    private func assertThrows<T>(
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

private final class WireMockURLProtocol: URLProtocol, @unchecked Sendable {
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
