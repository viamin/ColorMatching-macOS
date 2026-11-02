import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire-contract tests for `PaletteAPIClient` against the documented
/// `/api/v1` shapes (viamin/color_matching#110).
///
/// These pin the externally observable request/response behavior that the
/// migration to the generated OpenAPI client (issue #39) must preserve:
/// endpoint paths, query parameters, headers, snake_case decoding, and the
/// HTTP-status → `PaletteAPIError` mapping. They must stay green before and
/// after the migration.
final class PaletteAPIClientContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        ContractMockURLProtocol.handler = nil
    }

    // MARK: - Request shape

    func testFetchPrinterProfilesHitsAPIV1EndpointWithHeaders() async throws {
        let request = try await captureRequest { client in
            _ = try await client.fetchPrinterProfiles()
        }

        XCTAssertEqual(request.url, URL(string: "http://example.com/api/v1/printer_profiles"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
    }

    func testFetchColorsHitsAPIV1EndpointWithProfileQuery() async throws {
        let request = try await captureRequest { client in
            _ = try await client.fetchColors(printerProfileID: 7)
        }

        XCTAssertEqual(request.url, URL(string: "http://example.com/api/v1/colors?printer_profile_id=7"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
    }

    func testOmitsAuthorizationHeaderWhenNoTokenIsConfigured() async throws {
        let request = try await captureRequest(token: nil) { client in
            _ = try await client.fetchPrinterProfiles()
        }

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - Response decoding

    func testFetchPrinterProfilesDecodesSnakeCaseEnvelope() async throws {
        let profiles = try await withStubbedResponse(data: printerProfilesEnvelope()) { client in
            try await client.fetchPrinterProfiles()
        }

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].id, 7)
        XCTAssertEqual(profiles[0].printerMakeModel, "Canon PRO-1000")
        XCTAssertEqual(profiles[0].paperType, "Matte")
        XCTAssertEqual(profiles[0].inkType, "Pigment")
        XCTAssertEqual(profiles[0].displayName, "Canon PRO-1000 · Matte · Pigment")
    }

    func testFetchColorsDecodesEnvelopeProfileAndResponseVectors() async throws {
        let fetched = try await withStubbedResponse(data: colorsEnvelope()) { client in
            try await client.fetchColors(printerProfileID: 7)
        }

        XCTAssertEqual(fetched.profile?.id, 7)
        XCTAssertEqual(fetched.profile?.printerMakeModel, "Canon PRO-1000")
        XCTAssertEqual(fetched.colors.count, 2)

        let first = fetched.colors[0]
        XCTAssertEqual(first.id, 10)
        XCTAssertEqual(first.name, "Sienna")
        XCTAssertEqual(first.hex, "#A0522D")
        XCTAssertEqual(first.rgb?.r, 160)
        XCTAssertEqual(first.rgb?.g, 82)
        XCTAssertEqual(first.rgb?.b, 45)
        XCTAssertEqual(first.paletteId, 3)
        XCTAssertEqual(first.paletteName, "Earth tones")
        XCTAssertEqual(first.sortOrder, 1)
        let white = first.responses["white"]
        XCTAssertEqual(white?.brightness, 0.375)
        XCTAssertEqual(white?.source, "measurement")
        XCTAssertEqual(white?.rawValue, 41.2)
        XCTAssertEqual(white?.rawUnit, "cd/m²")
        XCTAssertEqual(white?.apparentBrightness, 4)
        XCTAssertEqual(white?.testRunId, "run-1")

        let domain = try XCTUnwrap(first.toDomain())
        XCTAssertEqual(Set(domain.responses.keys), [.white, .lps], "non-canonical light-source keys are dropped")
        XCTAssertEqual(domain.brightness(for: .white), 0.375)
        XCTAssertEqual(domain.brightness(for: .lps), 0.125)
        XCTAssertEqual(domain.rgb, RGBColor(red: 160, green: 82, blue: 45))

        let second = fetched.colors[1]
        XCTAssertNil(second.rgb)
        let secondDomain = try XCTUnwrap(second.toDomain())
        XCTAssertEqual(secondDomain.rgb, RGBColor(hex: "#708090"), "rgb falls back to the hex field")
        XCTAssertTrue(secondDomain.responses.isEmpty)
    }

    // MARK: - Error mapping

    func testFetchColorsMapsUnauthorizedToReauthenticableError() async {
        await assertAsyncThrows(status: 401, body: Data()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testFetchColorsMapsServiceUnavailableToBadStatus() async {
        await assertAsyncThrows(status: 503, body: Data()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testFetchColorsMapsUndecodableBodyToMalformedResponse() async {
        await assertAsyncThrows(status: 200, body: Data("{".utf8)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - Stubbing plumbing

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

    private func captureRequest(
        token: String? = "secret-token",
        exercise: (PaletteAPIClient) async throws -> Void
    ) async throws -> URLRequest {
        let lock = NSLock()
        var captured: URLRequest?
        let client = makeClient(token: token) { request in
            lock.lock()
            captured = request
            lock.unlock()
            return contractOKResponse(for: request, data: Data("{\"printer_profiles\": [], \"colors\": [], \"printer_profile\": null}".utf8))
        }
        try await exercise(client)
        return try XCTUnwrap(captured)
    }

    private func withStubbedResponse<T>(
        data: Data,
        run: (PaletteAPIClient) async throws -> T
    ) async throws -> T {
        let client = makeClient(token: "secret-token") { request in
            contractOKResponse(for: request, data: data)
        }
        return try await run(client)
    }

    private func assertAsyncThrows(
        status: Int,
        body: Data,
        assertions: @escaping (Error) -> Void
    ) async {
        let client = makeClient(token: "secret-token") { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
        }
        do {
            _ = try await client.fetchColors(printerProfileID: 7)
            XCTFail("Expected error to be thrown")
        } catch {
            assertions(error)
        }
    }

    // MARK: - Wire fixtures (snake_case, as emitted by /api/v1)

    private func printerProfilesEnvelope() -> Data {
        """
        {
          "printer_profiles": [
            {
              "id": 7,
              "printer_make_model": "Canon PRO-1000",
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
          "printer_profile": {
            "id": 7,
            "printer_make_model": "Canon PRO-1000",
            "paper_type": "Matte",
            "ink_type": "Pigment"
          },
          "colors": [
            {
              "id": 10,
              "name": "Sienna",
              "hex": "#A0522D",
              "rgb": {"r": 160, "g": 82, "b": 45},
              "palette_id": 3,
              "palette_name": "Earth tones",
              "sort_order": 1,
              "responses": {
                "white": {
                  "brightness": 0.375,
                  "source": "measurement",
                  "raw_value": 41.2,
                  "raw_unit": "cd/m²",
                  "apparent_brightness": 4,
                  "measured_at": "2026-01-01T00:00:00Z",
                  "test_run_id": "run-1"
                },
                "lps": {"brightness": 0.125},
                "ultraviolet": {"brightness": 0.9}
              }
            },
            {
              "id": 11,
              "name": null,
              "hex": "#708090",
              "rgb": null,
              "palette_id": 3,
              "sort_order": 2,
              "responses": {}
            }
          ]
        }
        """.data(using: .utf8)!
    }
}

private func contractOKResponse(for request: URLRequest, data: Data) -> (HTTPURLResponse, Data) {
    (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
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
