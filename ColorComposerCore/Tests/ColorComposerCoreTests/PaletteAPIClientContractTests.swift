import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Behavioral wire contract of `PaletteAPIClient` against the
/// `color_matching` `/api/v1` endpoints.
///
/// These tests exist to lock the client's observable behavior across the
/// migration to the generated OpenAPI client (issue #39): whatever sits below
/// `PaletteAPIClient` — hand-rolled `URLSession` + `JSONDecoder` or a wrapped
/// `swift-openapi-runtime` client — must keep issuing the same requests and
/// decoding the same wire payloads into the same DTOs, because
/// `ProfileColorCache` persists those DTOs to disk for offline fallback.
final class PaletteAPIClientContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.handler = nil
    }

    // MARK: - printer_profiles

    func testFetchPrinterProfilesRequestsVersionedJSONEndpoint() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/api/v1/printer_profiles")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles[0].id, 1)
        XCTAssertEqual(profiles[0].printerMakeModel, "Epson P700")
        XCTAssertEqual(profiles[0].paperType, "Matte")
        XCTAssertEqual(profiles[0].inkType, "Pigment")
        XCTAssertEqual(profiles[0].displayName, "Epson P700 · Matte · Pigment")
        XCTAssertEqual(profiles[1].id, 2)
        XCTAssertEqual(profiles[1].printerMakeModel, "Canon Pro 300")
    }

    // MARK: - colors

    func testFetchColorsSendsProfileIDQueryAndDecodesEnvelope() async throws {
        let client = makeClient { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/api/v1/colors")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(
                items.contains { $0.name == "printer_profile_id" && $0.value == "7" },
                "expected printer_profile_id=7 in \(items)"
            )
            return (.init(statusCode: 200, url: url), Self.colorsBody)
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(fetched.profile?.id, 7)
        XCTAssertEqual(fetched.colors.count, 2)

        let measured = try XCTUnwrap(fetched.colors.first { $0.id == 101 })
        XCTAssertEqual(measured.hex, "#C64A35")
        XCTAssertEqual(measured.rgb?.r, 198)
        XCTAssertEqual(measured.rgb?.g, 74)
        XCTAssertEqual(measured.rgb?.b, 53)
        XCTAssertEqual(measured.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(measured.responses["red"]?.source, "measurement")
        XCTAssertEqual(measured.responses["lps"]?.source, "response")
        XCTAssertEqual(measured.responses["lps"]?.apparentBrightness, 5)
        XCTAssertNil(measured.responses["green"], "unmeasured conditions must be absent, not zero")
    }

    func testFetchColorsKeepsResponselessColorsForSolverExclusion() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsWithNoResponsesBody)
        }

        let fetched = try await client.fetchColors(printerProfileID: 3)

        let responseless = try XCTUnwrap(fetched.colors.first { $0.id == 900 })
        let domain = try XCTUnwrap(responseless.toDomain())

        XCTAssertTrue(domain.responses.isEmpty, "a color with no measurements must stay response-less")
        XCTAssertEqual(
            WeightedSquaredErrorScorer().score(
                candidate: domain,
                target: TargetResponseVector([.red: 0.5]),
                weights: ChannelWeights(red: 1)
            ),
            .excluded,
            "the solver must exclude colors without a measurement for a weighted condition"
        )
    }

    // MARK: - Auth handling

    func testClientOmitsAuthorizationHeaderWhenTokenIsBlank() async throws {
        let lock = NSLock()
        var authorization: String?
        let client = makeClient(token: "   ", handler: { request in
            lock.lock()
            authorization = request.value(forHTTPHeaderField: "Authorization")
            lock.unlock()
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        })

        _ = try await client.fetchPrinterProfiles()

        XCTAssertNil(authorization, "a whitespace-only token must not produce an Authorization header")
    }

    func testFetchColorsMapsNon2xxToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testFetchPrinterProfilesMapsUndecodableBodyToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testTestConnectionAcceptsAny2xx() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
            return (.init(statusCode: 204, url: request.url!), Data())
        }

        try await client.testConnection()
    }

    // MARK: - Fixtures

    private static let printerProfilesBody: Data = """
    {
      "printer_profiles": [
        {
          "id": 1,
          "printer_make_model": "Epson P700",
          "paper_type": "Matte",
          "ink_type": "Pigment"
        },
        {
          "id": 2,
          "printer_make_model": "Canon Pro 300",
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
        "printer_make_model": "Epson P700",
        "paper_type": "Matte",
        "ink_type": "Pigment"
      },
      "colors": [
        {
          "id": 101,
          "name": "Red 12",
          "hex": "#C64A35",
          "rgb": {"r": 198, "g": 74, "b": 53},
          "palette_id": 5,
          "palette_name": "Default",
          "sort_order": 12,
          "responses": {
            "red": {"brightness": 0.87, "source": "measurement", "raw_value": 42.1, "raw_unit": "lux", "apparent_brightness": null, "measured_at": "2026-01-01T00:00:00Z", "test_run_id": "run-1"},
            "lps": {"brightness": 0.52, "source": "response", "apparent_brightness": 5, "raw_value": null, "raw_unit": null, "measured_at": null, "test_run_id": null}
          }
        },
        {
          "id": 102,
          "name": "Violet 3",
          "hex": "#6A5ACD",
          "responses": {}
        }
      ]
    }
    """.data(using: .utf8)!

    private static let colorsWithNoResponsesBody: Data = """
    {
      "printer_profile": {
        "id": 3,
        "printer_make_model": "Epson P700",
        "paper_type": "Matte",
        "ink_type": "Pigment"
      },
      "colors": [
        {"id": 900, "name": "Unmeasured", "hex": "#123456", "rgb": {"r": 18, "g": 52, "b": 86}, "responses": {}}
      ]
    }
    """.data(using: .utf8)!

    private func makeClient(
        token: String? = "secret-token",
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(
            baseURL: URL(string: "https://api.example.com")!,
            token: token,
            session: session
        )
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
            client?.urlProtocol(self, didFinishLoading: self)
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
