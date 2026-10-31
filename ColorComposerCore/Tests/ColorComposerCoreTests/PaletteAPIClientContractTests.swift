#if canImport(Darwin)
import Foundation
import XCTest
@testable import ColorComposerCore

/// Wire-contract pins for `PaletteAPIClient` against `color_matching`
/// `/api/v1`, guarding the migration to the OpenAPI-generated client
/// (viamin/color_matching#110 → issue #39): whatever transport layer lands,
/// these observable behaviors — versioned endpoint paths, query parameter,
/// JSON `Accept` + bearer-token headers, distinct error mapping for
/// 401 / non-2xx / malformed bodies, and the snake_case envelope shapes that
/// feed the disk cache (including the embedded profile used as the cached
/// profile fallback) — must not change.
final class PaletteAPIClientContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        RecordingURLProtocol.handler = nil
        RecordingURLProtocol.resetRequests()
    }

    func testPrinterProfilesHitsVersionedEndpointWithJSONAccept() async throws {
        let client = makeClient(body: profilesEnvelope)

        let profiles = try await client.fetchPrinterProfiles()

        let request = try XCTUnwrap(RecordingURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "http://api.example.com/api/v1/printer_profiles")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(profiles.map(\.id), [3])
        XCTAssertEqual(profiles.first?.printerMakeModel, "Canon PRO-1000")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
        XCTAssertEqual(profiles.first?.inkType, "Pigment")
    }

    func testColorsHitsVersionedEndpointWithProfileQueryParameter() async throws {
        let client = makeClient(body: colorsEnvelope)

        let fetched = try await client.fetchColors(printerProfileID: 7)

        let request = try XCTUnwrap(RecordingURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://api.example.com/api/v1/colors?printer_profile_id=7")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(fetched.colors.map(\.id), [11, 12])
        XCTAssertEqual(fetched.profile?.id, 7)
        XCTAssertEqual(fetched.profile?.printerMakeModel, "Canon PRO-1000")
    }

    func testColorsEnvelopeWithoutEmbeddedProfileDecodesNilProfile() async throws {
        let client = makeClient(body: """
            {"colors": [{"id": 12, "hex": "#112233", "responses": {}}], "printer_profile": null}
            """)

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertNil(fetched.profile)
        XCTAssertEqual(fetched.colors.map(\.id), [12])
    }

    func testBaseURLPathPrefixIsKeptBeforeVersionedSegment() async throws {
        let client = makeClient(baseURL: "http://api.example.com/prefix", body: profilesEnvelope)

        _ = try await client.fetchPrinterProfiles()

        XCTAssertEqual(
            RecordingURLProtocol.requests.first?.url?.absoluteString,
            "http://api.example.com/prefix/api/v1/printer_profiles"
        )
    }

    func testNoTokenSendsNoAuthorizationHeader() async throws {
        let client = makeClient(token: nil, body: profilesEnvelope)

        _ = try await client.fetchPrinterProfiles()

        XCTAssertNil(RecordingURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testUnauthorizedSurfacesDistinctError() async {
        let client = makeClient(status: 401, body: "{}")

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testNon2xxSurfacesBadStatus() async {
        let client = makeClient(status: 503, body: "{}")

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testUndecodableBodySurfacesMalformedResponse() async {
        let client = makeClient(body: "<html>not json</html>")

        await XCTAssertThrowsErrorAsync(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    /// The colors payload must survive the full wire → DTO → domain → scorer
    /// pipeline: unknown light-source keys are ignored (not dropped colors),
    /// merged responses keep normalized brightness, and a response-less color
    /// is excluded by the scorer rather than treated as zero brightness.
    func testColorsPayloadConvertsToSolverPaletteAndExcludesUnmeasured() async throws {
        let client = makeClient(body: colorsEnvelope)

        let fetched = try await client.fetchColors(printerProfileID: 7)

        let domain = try fetched.colors.compactMap { $0.toDomain() }
        XCTAssertEqual(domain.map(\.id), [11, 12])

        let measured = try XCTUnwrap(domain.first { $0.id == 11 })
        XCTAssertEqual(measured.responses.count, 2, "unknown light-source keys must be ignored, canonical ones kept")
        XCTAssertEqual(measured.brightness(for: .red), 0.3)
        XCTAssertEqual(measured.brightness(for: .green), 0.6)
        XCTAssertNil(measured.responses[.red]?.rawValue)

        let unmeasured = try XCTUnwrap(domain.first { $0.id == 12 })
        let weights = ChannelWeights(red: 1, green: 1)
        let target = TargetResponseVector([.red: 0.5, .green: 0.5])
        XCTAssertEqual(
            WeightedSquaredErrorScorer().score(candidate: unmeasured, target: target, weights: weights),
            .excluded,
            "a response-less color must be excluded, never scored as zero brightness"
        )
    }

    // MARK: - Fixtures

    private let profilesEnvelope = """
        {"printer_profiles": [{"id": 3, "printer_make_model": "Canon PRO-1000", "paper_type": "Matte", "ink_type": "Pigment"}]}
        """

    private let colorsEnvelope = """
        {
          "colors": [
            {
              "id": 11,
              "name": "Measured Swatch",
              "hex": "#aabbcc",
              "rgb": {"r": 170, "g": 187, "b": 204},
              "palette_id": 3,
              "palette_name": "Studio",
              "sort_order": 2,
              "responses": {
                "red": {"brightness": 0.3, "source": "response", "apparent_brightness": 3, "measured_at": "2026-01-02T03:04:05Z"},
                "green": {"brightness": 0.6, "source": "measurement", "raw_value": 120.5, "raw_unit": " lux"},
                "ultraviolet": {"brightness": 0.9}
              }
            },
            {"id": 12, "name": "Unmeasured Swatch", "hex": "#112233", "responses": {}}
          ],
          "printer_profile": {"id": 7, "printer_make_model": "Canon PRO-1000", "paper_type": "Matte", "ink_type": "Pigment"}
        }
        """

    private func makeClient(
        baseURL: String = "http://api.example.com",
        token: String? = "secret-token",
        status: Int = 200,
        body: String
    ) -> PaletteAPIClient {
        let bodyData = Data(body.utf8)
        RecordingURLProtocol.handler = { request in
            RecordingURLProtocol.record(request)
            return (HTTPURLResponse(statusCode: status, url: request.url!), bodyData)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        return PaletteAPIClient(
            baseURL: URL(string: baseURL)!,
            token: token,
            session: URLSession(configuration: configuration)
        )
    }
}

private final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) private static var recordedRequests: [URLRequest] = []
    private static let lock = NSLock()

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    static func record(_ request: URLRequest) {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()
    }

    static func resetRequests() {
        lock.lock()
        recordedRequests = []
        lock.unlock()
    }

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
#endif
