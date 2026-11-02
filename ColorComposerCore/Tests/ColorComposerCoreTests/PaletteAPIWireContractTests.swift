import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire-contract harness for the `/api/v1` surface `PaletteAPIClient` consumes.
///
/// These tests pin the externally observable HTTP behavior — endpoint paths,
/// headers, bearer-token handling, status mapping, and the JSON envelope
/// shapes — so the migration to the generated OpenAPI client
/// (swift-openapi-generator / swift-openapi-runtime, issue #39) can be
/// verified behavior-preserving: every assertion here must keep passing
/// unchanged after the migration.
final class PaletteAPIWireContractTests: XCTestCase {
    private var recorded: RecordedRequests!

    override func tearDown() {
        super.tearDown()
        WireContractMockURLProtocol.handler = nil
    }

    // MARK: - Endpoint contract

    func testFetchPrinterProfilesRequestsVersionedJSONEndpoint() async throws {
        let client = makeClient(token: "token-1") { request in
            (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(path(at: 0), "/api/v1/printer_profiles")
        XCTAssertEqual(header("Accept", at: 0), "application/json")
        XCTAssertEqual(header("Authorization", at: 0), "Bearer token-1")
        XCTAssertEqual(profiles.map(\.id), [1, 2])
        XCTAssertEqual(profiles[0].printerMakeModel, "Example Printer")
        XCTAssertEqual(profiles[0].paperType, "Matte")
        XCTAssertEqual(profiles[0].inkType, "Pigment")
    }

    func testFetchColorsRequestsProfileScopedEndpoint() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsBody)
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(path(at: 0), "/api/v1/colors")
        XCTAssertEqual(queryItem("printer_profile_id", at: 0), "7")
        XCTAssertEqual(fetched.profile?.id, 3)
        XCTAssertEqual(fetched.colors.map(\.id), [11, 12])
    }

    func testFetchColorsAcceptsNullPrinterProfileInEnvelope() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsBodyWithoutProfile)
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(fetched.profile, nil, "printer_profile is optional in the colors envelope")
        XCTAssertEqual(fetched.colors.count, 1)
    }

    /// The colors envelope carries provenance fields the generated client must
    /// preserve verbatim: snake_case keys, nested response objects, and RGB.
    func testFetchColorsDecodesResponseProvenanceFields() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsBody)
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        let first = try XCTUnwrap(fetched.colors.first)
        XCTAssertEqual(first.id, 11)
        XCTAssertEqual(first.hex, "#808080")
        XCTAssertEqual(first.rgb?.r, 128)
        XCTAssertEqual(first.rgb?.g, 128)
        XCTAssertEqual(first.rgb?.b, 128)
        XCTAssertEqual(first.paletteId, 4)
        XCTAssertEqual(first.paletteName, "Rheinhessen grays")
        XCTAssertEqual(first.sortOrder, 2)

        let response = try XCTUnwrap(first.responses["white"])
        XCTAssertEqual(response.brightness, 0.55, accuracy: 1e-12)
        XCTAssertEqual(response.source, "measurement")
        XCTAssertEqual(response.apparentBrightness, nil)
        XCTAssertEqual(response.rawValue ?? 0, 12.3, accuracy: 1e-12)
        XCTAssertEqual(response.rawUnit, "mV")
        XCTAssertEqual(response.measuredAt, "2026-01-01T00:00:00Z")
        XCTAssertEqual(response.testRunId, "run-9")

        let domain = try XCTUnwrap(first.toDomain())
        XCTAssertEqual(domain.brightness(for: .white), 0.55, accuracy: 1e-12)
        XCTAssertEqual(domain.responses[.white]?.rawValue ?? 0, 12.3, accuracy: 1e-12)
        XCTAssertEqual(domain.rgb.red, 128)
    }

    func testTestConnectionSucceedsOnAny2xx() async throws {
        let client = makeClient { request in
            // 204 carries no body: reachability must not require a decodable envelope.
            (.init(statusCode: 204, url: request.url!), Data())
        }

        try await client.testConnection()

        XCTAssertEqual(path(at: 0), "/api/v1/printer_profiles")
    }

    // MARK: - Auth and status mapping

    func testOmitsAuthorizationHeaderWithoutUsableToken() async throws {
        for token in [nil, "", "   "] as [String?] {
            let client = makeClient(token: token) { request in
                (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
            }

            _ = try await client.fetchPrinterProfiles()

            XCTAssertEqual(
                header("Authorization", at: 0),
                nil,
                "token \(token ?? "nil") must not produce an Authorization header"
            )
        }
    }

    func testNon2xxStatusMapsToBadStatus() async {
        for status in [404, 422, 500, 503] {
            let client = makeClient { request in
                (.init(statusCode: status, url: request.url!), Data())
            }

            await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
                XCTAssertEqual(error as? PaletteAPIError, .badStatus(status))
            }
        }
    }

    func testUndecodableSuccessBodyMapsToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - Helpers

    /// Installs a fresh recorder plus the given responder on the mock protocol
    /// and returns a client wired to it.
    private func makeClient(
        token: String? = nil,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        let recorder = RecordedRequests()
        recorded = recorder
        WireContractMockURLProtocol.handler = { request in
            recorder.append(request)
            return try handler(request)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WireContractMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(
            baseURL: URL(string: "http://example.com")!,
            token: token,
            session: session
        )
    }

    private func path(at index: Int) -> String? {
        recorded.values[index].url?.path
    }

    private func queryItem(_ name: String, at index: Int) -> String? {
        guard let url = recorded.values[index].url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }

    private func header(_ name: String, at index: Int) -> String? {
        recorded.values[index].value(forHTTPHeaderField: name)
    }

    private static let printerProfilesBody = """
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
          "paper_type": null,
          "ink_type": null
        }
      ]
    }
    """.data(using: .utf8)!

    private static let colorsBody = """
    {
      "colors": [
        {
          "id": 11,
          "name": "Neutral gray",
          "hex": "#808080",
          "rgb": { "r": 128, "g": 128, "b": 128 },
          "palette_id": 4,
          "palette_name": "Rheinhessen grays",
          "sort_order": 2,
          "responses": {
            "white": {
              "brightness": 0.55,
              "source": "measurement",
              "apparent_brightness": null,
              "raw_value": 12.3,
              "raw_unit": "mV",
              "measured_at": "2026-01-01T00:00:00Z",
              "test_run_id": "run-9"
            },
            "red": {
              "brightness": 0.2,
              "source": "response",
              "apparent_brightness": 2,
              "raw_value": null,
              "raw_unit": null,
              "measured_at": null,
              "test_run_id": null
            }
          }
        },
        {
          "id": 12,
          "name": null,
          "hex": "#336699",
          "rgb": null,
          "palette_id": null,
          "palette_name": null,
          "sort_order": null,
          "responses": {}
        }
      ],
      "printer_profile": {
        "id": 3,
        "printer_make_model": "Example Printer",
        "paper_type": "Matte",
        "ink_type": "Pigment"
      }
    }
    """.data(using: .utf8)!

    private static let colorsBodyWithoutProfile = """
    {
      "colors": [
        {
          "id": 11,
          "hex": "#808080",
          "responses": {}
        }
      ],
      "printer_profile": null
    }
    """.data(using: .utf8)!
}

/// Collects intercepted requests under a lock (the mock protocol may run off
/// the test actor).
private final class RecordedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        values.append(request)
        lock.unlock()
    }
}

private final class WireContractMockURLProtocol: URLProtocol, @unchecked Sendable {
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
