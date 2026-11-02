import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire-contract pinning for `PaletteAPIClient` (issue #39).
///
/// The client is being migrated onto the OpenAPI-generated client from the
/// `color_matching` spec (viamin/color_matching#110). These tests freeze the
/// observable HTTP contract — request construction, authorization, envelope
/// decoding (shaped like the published spec), and error mapping — so the
/// migration cannot change behavior. `ProfileColorCacheTests` additionally
/// guards the disk-cache / offline-stale layers that sit on top.
///
/// Spec-shape notes (from `GET /api/v1/openapi.json`): `PrinterProfile`
/// fields are all required; each colors entry requires `id`, `name`, `hex`,
/// `palette_id`, `sort_order`, `responses`; `palette_name` is nullable and
/// `rgb` optional; `responses` is a free-form object (unknown light sources
/// may appear). See `docs/openapi-client-migration.md`.
final class PaletteAPIClientContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        ContractMockURLProtocol.handler = nil
    }

    // MARK: - Request construction

    func testPrinterProfilesRequestTargetsCanonicalAPIV1Path() async throws {
        let request = try await captureRequest(for: .printerProfiles)
        XCTAssertEqual(request.url?.absoluteString, "http://api.example.com/api/v1/printer_profiles")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testColorsRequestCarriesPrinterProfileIDQuery() async throws {
        let request = try await captureRequest(for: .colors(profileID: 42))
        XCTAssertEqual(request.url?.absoluteString, "http://api.example.com/api/v1/colors?printer_profile_id=42")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testRequestsAppendToABaseURLPath() async throws {
        let request = try await captureRequest(for: .printerProfiles, baseURL: "http://api.example.com/prefix")
        XCTAssertEqual(request.url?.absoluteString, "http://api.example.com/prefix/api/v1/printer_profiles")
    }

    func testOmittedTokenSendsNoAuthorizationHeader() async throws {
        let request = try await captureRequest(for: .printerProfiles, token: nil)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testWhitespaceOnlyTokenSendsNoAuthorizationHeader() async throws {
        let request = try await captureRequest(for: .printerProfiles, token: "   ")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testTokenIsSentTrimmedAsBearer() async throws {
        let request = try await captureRequest(for: .printerProfiles, token: " secret ")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }

    // MARK: - Envelope decoding (spec-shaped payloads)

    func testFetchPrinterProfilesDecodesSpecShapedEnvelope() async throws {
        enqueue(body: Self.specShapedProfilesJSON)
        let client = makeClient()

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.map(\.id), [1, 2])
        XCTAssertEqual(profiles.first?.printerMakeModel, "Epson P900")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
        XCTAssertEqual(profiles.first?.inkType, "Pigment")
    }

    func testFetchColorsDecodesSpecShapedEnvelopeEndToEnd() async throws {
        enqueue(body: Self.specShapedColorsJSON)
        let client = makeClient()

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(fetched.profile?.id, 7)
        XCTAssertEqual(fetched.colors.map(\.id), [123, 124])
        assertDomainConversion(fetched.colors)
    }

    /// The full decode → `toDomain` pipeline the solver consumes: canonical
    /// light sources become responses, unknown keys are dropped, an absent
    /// `rgb` falls back to `hex`, and a null `palette_name` stays nil.
    private func assertDomainConversion(_ colors: [PaletteColorDTO]) {
        let first = colors[0].toDomain()
        XCTAssertEqual(first?.brightness(for: .red), 0.87)
        XCTAssertNil(first?.brightness(for: .green), "absent response must stay missing, never zero")
        XCTAssertEqual(first?.responses.count, 1, "unknown light sources are dropped in conversion")
        XCTAssertEqual(first?.paletteName, "Default")
        XCTAssertEqual(first?.rgb, RGBColor(red: 198, green: 74, blue: 53))

        let second = colors[1].toDomain()
        XCTAssertEqual(second?.rgb, RGBColor(hex: "#112233"), "rgb-omitted color falls back to hex")
        XCTAssertNil(second?.paletteName)
        XCTAssertEqual(second?.responses.count, 0)
    }

    // MARK: - Error mapping

    func testFetchColorsMaps401ToUnauthorized() async {
        enqueue(status: 401)
        let client = makeClient()
        await expectPaletteAPIError(try await client.fetchColors(printerProfileID: 1), .unauthorized)
    }

    func testFetchColorsMaps500ToBadStatus() async {
        enqueue(status: 500)
        let client = makeClient()
        await expectPaletteAPIError(try await client.fetchColors(printerProfileID: 1), .badStatus(500))
    }

    func testMalformedBodyThrowsMalformedResponse() async {
        enqueue(body: Data("not json".utf8))
        let client = makeClient()
        await expectPaletteAPIError(try await client.fetchPrinterProfiles(), .malformedResponse)
    }

    func testTestConnectionAcceptsAny2xx() async throws {
        enqueue(status: 204)
        let client = makeClient()

        try await client.testConnection()
    }

    // MARK: - Fixtures

    private static let specShapedProfilesJSON = Data("""
    {
      "printer_profiles": [
        {"id": 1, "printer_make_model": "Epson P900", "paper_type": "Matte", "ink_type": "Pigment"},
        {"id": 2, "printer_make_model": "Canon Pro-300", "paper_type": "Glossy", "ink_type": "Dye"}
      ]
    }
    """.utf8)

    /// Shaped per the published OpenAPI spec: `name` present (required),
    /// `palette_name` null (nullable), `rgb` omitted on the second entry
    /// (optional), `responses` carrying one canonical and one unknown key.
    private static let specShapedColorsJSON = Data("""
    {
      "printer_profile": {"id": 7, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Pigment"},
      "colors": [
        {
          "id": 123, "name": "Red 12", "hex": "#C64A35",
          "rgb": {"r": 198, "g": 74, "b": 53},
          "palette_id": 5, "palette_name": "Default", "sort_order": 12,
          "responses": {
            "red": {"brightness": 0.87, "source": "measurement"},
            "ultraviolet": {"brightness": 0.9}
          }
        },
        {
          "id": 124, "name": "Plain", "hex": "#112233",
          "palette_id": 5, "palette_name": null, "sort_order": 13,
          "responses": {}
        }
      ]
    }
    """.utf8)

    // MARK: - Harness

    private enum Resource {
        case printerProfiles
        case colors(profileID: Int)
    }

    private func makeClient(
        baseURL: String = "http://api.example.com",
        token: String? = "secret"
    ) -> PaletteAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContractMockURLProtocol.self]
        return PaletteAPIClient(
            baseURL: URL(string: baseURL)!,
            token: token,
            session: URLSession(configuration: configuration)
        )
    }

    private func enqueue(status: Int = 200, body: Data = Data("{}".utf8)) {
        ContractMockURLProtocol.handler = { request in
            (contractResponse(status: status, url: request.url!), body)
        }
    }

    private func captureRequest(
        for resource: Resource,
        baseURL: String = "http://api.example.com",
        token: String? = "secret"
    ) async throws -> URLRequest {
        let box = RequestBox()
        ContractMockURLProtocol.handler = { request in
            box.store(request)
            return (contractResponse(status: 200, url: request.url!), Data("{}".utf8))
        }
        let client = makeClient(baseURL: baseURL, token: token)
        _ = try await Self.invoke(client, resource)
        return try XCTUnwrap(box.request)
    }

    private static func invoke(_ client: PaletteAPIClient, _ resource: Resource) async throws {
        switch resource {
        case .printerProfiles: _ = try await client.fetchPrinterProfiles()
        case .colors(let profileID): _ = try await client.fetchColors(printerProfileID: profileID)
        }
    }

    private func expectPaletteAPIError<T>(
        _ expression: @autoclosure () async throws -> T,
        _ expected: PaletteAPIError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected \(expected) to be thrown", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? PaletteAPIError, expected, file: file, line: line)
        }
    }
}

private func contractResponse(status: Int, url: URL) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

/// Thread-safe single-request capture for the mock protocol's handler.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var request: URLRequest?

    func store(_ request: URLRequest) {
        lock.lock()
        self.request = request
        lock.unlock()
    }
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
