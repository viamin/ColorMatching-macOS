import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Pins the `/api/v1` wire contract `PaletteAPIClient` consumes.
///
/// These tests are the migration safety net for adopting the generated
/// OpenAPI client (issue #39): whatever sits behind `PaletteAPIClient` after
/// the migration — a wrapped generated client or a rewrite — must keep this
/// exact wire behavior: the same endpoints, headers, token handling, envelope
/// decoding, and error mapping. They intentionally assert observable HTTP
/// behavior only, never implementation types.
final class PaletteAPIClientWireContractTests: XCTestCase {
    private var log: RequestLog!

    override func setUp() {
        super.setUp()
        log = RequestLog()
    }

    override func tearDown() {
        WireMockURLProtocol.handler = nil
        log = nil
        super.tearDown()
    }

    // MARK: - printer_profiles

    func testFetchPrinterProfilesRequestsTheV1EndpointAndDecodesTheEnvelope() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.printerProfilesJSON)
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(self.singleRecordedRequest()?.url?.path, "/api/v1/printer_profiles")
        XCTAssertEqual(
            self.singleRecordedRequest()?.httpMethod?.uppercased() ?? "GET",
            "GET",
            "printer_profiles must be fetched with GET"
        )
        XCTAssertEqual(
            self.singleRecordedRequest()?.value(forHTTPHeaderField: "Accept"),
            "application/json"
        )
        XCTAssertNil(
            self.singleRecordedRequest()?.value(forHTTPHeaderField: "Authorization"),
            "no bearer header may be sent when no token is configured"
        )
        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles[0].id, 1)
        XCTAssertEqual(profiles[0].printerMakeModel, "Example Printer")
        XCTAssertEqual(profiles[0].paperType, "Matte")
        XCTAssertEqual(profiles[0].inkType, "Pigment")
        XCTAssertEqual(profiles[1].id, 2)
        XCTAssertNil(profiles[1].printerMakeModel)
    }

    // MARK: - colors

    func testFetchColorsRequestsTheProfileScopedV1EndpointAndDecodesTheEnvelope() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsJSON)
        }

        let (colors, profile) = try await client.fetchColors(printerProfileID: 3)

        let request = try XCTUnwrap(self.singleRecordedRequest())
        XCTAssertEqual(request.url?.path, "/api/v1/colors")
        XCTAssertEqual(request.url?.query, "printer_profile_id=3")
        XCTAssertEqual(request.httpMethod?.uppercased() ?? "GET", "GET", "colors must be fetched with GET")

        XCTAssertEqual(colors.count, 2)
        XCTAssertEqual(profile?.id, 3)

        let measured = try XCTUnwrap(colors.first { $0.id == 1 }.flatMap { $0.toDomain() })
        XCTAssertEqual(Set(measured.responses.keys), [.white, .lps], "unknown light-source keys must be dropped")
        XCTAssertEqual(measured.brightness(for: .white), 0.9)
        XCTAssertEqual(measured.brightness(for: .lps), 0.4)
        XCTAssertNil(measured.brightness(for: .red), "red was never measured")

        let hexOnly = try XCTUnwrap(colors.first { $0.id == 2 }.flatMap { $0.toDomain() })
        XCTAssertTrue(hexOnly.responses.isEmpty, "a response-less color decodes and converts but stays unmeasured")
    }

    func testFetchColorsAcceptsAnEnvelopeWithoutPrinterProfile() async throws {
        let client = makeClient { request in
            (
                .init(statusCode: 200, url: request.url!),
                """
                {"colors": [{"id": 9, "hex": "#001122", "responses": {"red": {"brightness": 0.5}}}]}
                """.data(using: .utf8)!
            )
        }

        let (colors, profile) = try await client.fetchColors(printerProfileID: 1)

        XCTAssertEqual(colors.count, 1)
        XCTAssertNil(profile, "printer_profile is optional in the envelope")
    }

    // MARK: - connection probe

    func testTestConnectionSucceedsOnAny2xx() async throws {
        let client = makeClient { request in
            (.init(statusCode: 204, url: request.url!), Data())
        }

        try await client.testConnection()

        XCTAssertEqual(self.singleRecordedRequest()?.url?.path, "/api/v1/printer_profiles")
    }

    // MARK: - error mapping

    func testNon2xxMapsToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await AssertAsyncThrowsError(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testUndecodableBodyMapsToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await AssertAsyncThrowsError(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - fixtures

    private static let printerProfilesJSON = """
    {
      "printer_profiles": [
        {
          "id": 1,
          "printer_make_model": "Example Printer",
          "paper_type": "Matte",
          "ink_type": "Pigment"
        },
        { "id": 2 }
      ]
    }
    """.data(using: .utf8)!

    private static let colorsJSON = """
    {
      "colors": [
        {
          "id": 1,
          "name": "Metamer Teal",
          "hex": "#00AAFF",
          "rgb": { "r": 0, "g": 170, "b": 255 },
          "palette_id": 5,
          "palette_name": "Set A",
          "sort_order": 2,
          "responses": {
            "white": {
              "brightness": 0.9,
              "source": "measurement",
              "raw_value": 41.2,
              "raw_unit": "cd/m2",
              "apparent_brightness": 8
            },
            "lps": { "brightness": 0.4 },
            "ultraviolet": { "brightness": 0.7 }
          }
        },
        { "id": 2, "hex": "#112233", "responses": {} }
      ],
      "printer_profile": {
        "id": 3,
        "printer_make_model": "Epson X",
        "paper_type": "Matte",
        "ink_type": "Pigment"
      }
    }
    """.data(using: .utf8)!

    // MARK: - mock plumbing

    /// Thread-safe request log: the URLProtocol handler runs on the session's
    /// queue while the test body reads from the main actor.
    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []

        func append(_ request: URLRequest) {
            lock.lock()
            requests.append(request)
            lock.unlock()
        }

        var all: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }
    }

    private func makeClient(
        respond: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        WireMockURLProtocol.handler = { [log] request in
            log.append(request)
            return respond(request)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WireMockURLProtocol.self]
        return PaletteAPIClient(
            baseURL: URL(string: "http://example.com")!,
            token: nil,
            session: URLSession(configuration: configuration)
        )
    }

    private func singleRecordedRequest() -> URLRequest? {
        XCTAssertEqual(log.all.count, 1, "expected exactly one request")
        return log.all.first
    }
}

private extension HTTPURLResponse {
    convenience init(statusCode: Int, url: URL) {
        self.init(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
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

private func AssertAsyncThrowsError<T>(
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
