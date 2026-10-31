import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire contract of `PaletteAPIClient` against `color_matching` `/api/v1`.
///
/// Issue #39 migrates this client onto a generated OpenAPI client
/// (swift-openapi-generator + swift-openapi-runtime, fed by the spec published
/// in viamin/color_matching#110). Whatever transport ends up underneath, the
/// observable contract pinned here must not change — the disk cache stores the
/// same snake_case DTOs these endpoints return, so decoding drift silently
/// breaks offline-stale fallbacks and cached-profile pickers.
///
/// Every payload below mirrors the actual JSON rendered by
/// `ColorMatchingWeb.ColorPaletteController` (upstream `main`).
final class PaletteAPIClientContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.handler = nil
    }

    // MARK: - Endpoint shape

    func testPrinterProfilesRequestTargetsVersionedJSONEndpoint() async throws {
        let request = try await performPrinterProfilesRequest(token: nil)

        XCTAssertEqual(request.url?.absoluteString, "http://example.com/api/v1/printer_profiles")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testSubpathBaseURLKeepsTheVersionedPath() async throws {
        let request = try await performPrinterProfilesRequest(
            baseURL: URL(string: "http://example.com/prefix")!,
            token: nil
        )

        XCTAssertEqual(request.url?.absoluteString, "http://example.com/prefix/api/v1/printer_profiles")
    }

    func testColorsRequestCarriesTheProfileIDQueryParameter() async throws {
        let client = makeClient(token: nil) { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "http://example.com/api/v1/colors?printer_profile_id=42"
            )
            return (.init(statusCode: 200, url: request.url!), Self.colorsResponse())
        }

        _ = try await client.fetchColors(printerProfileID: 42)
    }

    // MARK: - Authorization

    func testPrinterProfilesRequestOmitsAuthorizationWithoutToken() async throws {
        let request = try await performPrinterProfilesRequest(token: nil)

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testPrinterProfilesRequestOmitsAuthorizationForWhitespaceOnlyToken() async throws {
        let request = try await performPrinterProfilesRequest(token: "   ")

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testColorsRequestSendsTrimmedBearerToken() async throws {
        let client = makeClient(token: "  tok-123  ") { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
            return (.init(statusCode: 200, url: request.url!), Self.colorsResponse())
        }

        _ = try await client.fetchColors(printerProfileID: 1)
    }

    // MARK: - Envelope decoding (upstream JSON shapes)

    func testPrinterProfilesDecodesSnakeCaseEnvelopeWithNullableFields() async throws {
        let client = makeClient(token: nil) { request in
            (.init(statusCode: 200, url: request.url!), Self.printerProfilesResponse())
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles[0], PrinterProfileDTO(
            id: 1, printerMakeModel: "Epson ET-8550", paperType: "Premium Matte", inkType: "Pigment"
        ))
        XCTAssertEqual(profiles[1], PrinterProfileDTO(id: 2, printerMakeModel: nil, paperType: nil, inkType: nil))
    }

    func testColorsDecodesResponsesWithMergedProvenanceFields() async throws {
        let client = makeClient(token: nil) { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsResponse())
        }

        let fetched = try await client.fetchColors(printerProfileID: 3)

        XCTAssertEqual(fetched.profile?.id, 3)
        XCTAssertEqual(fetched.profile?.paperType, "Luster")
        XCTAssertEqual(fetched.colors.count, 2)

        let measured = try XCTUnwrap(fetched.colors.first)
        XCTAssertEqual(measured.id, 101)
        XCTAssertEqual(measured.name, "Burnt Sienna")
        XCTAssertEqual(measured.hex, "#A0522D")
        XCTAssertEqual(measured.rgb, RGBDTO(r: 160, g: 82, b: 45))
        XCTAssertEqual(measured.paletteId, 7)
        XCTAssertEqual(measured.paletteName, "Autumn")
        XCTAssertEqual(measured.sortOrder, 2)
        XCTAssertEqual(measured.responses.keys.sorted(), ["lps", "red", "white"])

        let red = try XCTUnwrap(measured.responses["red"])
        XCTAssertEqual(red.brightness, 0.5)
        XCTAssertEqual(red.source, "measurement")
        XCTAssertEqual(red.rawValue, 12.4)
        XCTAssertEqual(red.rawUnit, "mV")
        XCTAssertNil(red.apparentBrightness)
        XCTAssertEqual(red.measuredAt, "2026-01-15T10:30:00Z")
        XCTAssertEqual(red.testRunId, "run-42")

        let white = try XCTUnwrap(measured.responses["white"])
        XCTAssertEqual(white.source, "response")
        XCTAssertEqual(white.apparentBrightness, 4)
        XCTAssertNil(white.rawValue)

        // A color with no measurements for the profile decodes response-less;
        // the solver excludes it rather than reading it as zero brightness.
        let unmeasured = try XCTUnwrap(fetched.colors.last)
        XCTAssertTrue(unmeasured.responses.isEmpty)
    }

    // MARK: - Error mapping

    func testColorsMaps401ToUnauthorized() async {
        let client = makeClient(token: "stale") { request in
            (.init(statusCode: 401, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testColorsMaps500ToBadStatus() async {
        let client = makeClient(token: nil) { request in
            (.init(statusCode: 500, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    func testColorsMapsUndecodableBodyToMalformedResponse() async {
        let client = makeClient(token: nil) { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testTestConnectionSucceedsOn2xxWithEmptyBody() async throws {
        let client = makeClient(token: nil) { request in
            (.init(statusCode: 200, url: request.url!), Data())
        }

        try await client.testConnection()
    }

    // MARK: - Helpers

    private func performPrinterProfilesRequest(
        baseURL: URL = URL(string: "http://example.com")!,
        token: String?
    ) async throws -> URLRequest {
        let lock = NSLock()
        var captured: URLRequest?
        let client = makeClient(baseURL: baseURL, token: token) { request in
            lock.lock()
            captured = request
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesResponse())
        }

        _ = try await client.fetchPrinterProfiles()

        lock.lock()
        let observed = captured
        lock.unlock()
        return try XCTUnwrap(observed, "expected the mock transport to observe the profiles request")
    }

    private func makeClient(
        baseURL: URL = URL(string: "http://example.com")!,
        token: String?,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return PaletteAPIClient(baseURL: baseURL, token: token, session: URLSession(configuration: configuration))
    }

    /// Rendered by `ColorPaletteController.printer_profiles/2` — snake_case
    /// keys, nullable descriptive fields.
    private static func printerProfilesResponse() -> Data {
        """
        {
          "printer_profiles": [
            {
              "id": 1,
              "printer_make_model": "Epson ET-8550",
              "paper_type": "Premium Matte",
              "ink_type": "Pigment"
            },
            {
              "id": 2,
              "printer_make_model": null,
              "paper_type": null,
              "ink_type": null
            }
          ]
        }
        """.data(using: .utf8)!
    }

    /// Rendered by `ColorPaletteController.colors/2` — human-entered responses
    /// (priority) merged with instrument measurements; light sources without a
    /// measurement are omitted from `responses`.
    private static func colorsResponse() -> Data {
        """
        {
          "printer_profile": {
            "id": 3,
            "printer_make_model": "Canon PRO-300",
            "paper_type": "Luster",
            "ink_type": "Dye"
          },
          "colors": [
            {
              "id": 101,
              "name": "Burnt Sienna",
              "hex": "#A0522D",
              "rgb": {"r": 160, "g": 82, "b": 45},
              "palette_id": 7,
              "palette_name": "Autumn",
              "sort_order": 2,
              "responses": {
                "white": {
                  "brightness": 0.375,
                  "source": "response",
                  "raw_value": null,
                  "raw_unit": null,
                  "apparent_brightness": 4,
                  "measured_at": null,
                  "test_run_id": null
                },
                "red": {
                  "brightness": 0.5,
                  "source": "measurement",
                  "raw_value": 12.4,
                  "raw_unit": "mV",
                  "apparent_brightness": null,
                  "measured_at": "2026-01-15T10:30:00Z",
                  "test_run_id": "run-42"
                },
                "lps": {
                  "brightness": 0.125,
                  "source": "response",
                  "raw_value": null,
                  "raw_unit": null,
                  "apparent_brightness": 1,
                  "measured_at": null,
                  "test_run_id": null
                }
              }
            },
            {
              "id": 102,
              "name": null,
              "hex": "#111111",
              "rgb": null,
              "palette_id": null,
              "palette_name": null,
              "sort_order": null,
              "responses": {}
            }
          ]
        }
        """.data(using: .utf8)!
    }
}

/// Same mock transport the existing `PaletteAPIClientTests` use; duplicated
/// (file-private) so both files stay independently runnable.
private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
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
