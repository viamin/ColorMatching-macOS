import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire contract of `PaletteAPIClient` (issue #39).
///
/// These tests pin the observable HTTP behavior of the client — endpoint
/// paths, query scoping, headers, bearer-token handling, status-code errors,
/// and envelope decoding — so the migration to the generated OpenAPI client
/// (swift-openapi-generator / swift-openapi-runtime) can be verified against
/// the current contract: whatever wraps the generated client, these calls and
/// errors must keep working unchanged.
final class PaletteAPIClientContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.handler = nil
    }

    private let baseURL = URL(string: "http://example.com")!

    // MARK: - Endpoint shape

    func testFetchPrinterProfilesRequestsTheApiV1Endpoint() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.map(\.id), [1, 4])
        XCTAssertEqual(profiles.first?.printerMakeModel, "Example Printer")
    }

    func testFetchColorsRequestsTheProfileScopedColorsEndpoint() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v1/colors")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            XCTAssertEqual(components?.queryItems?.first?.name, "printer_profile_id")
            XCTAssertEqual(components?.queryItems?.first?.value, "7")
            return (.init(statusCode: 200, url: request.url!), Self.colorsBody)
        }

        let result = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(result.colors.map(\.id), [123])
        XCTAssertEqual(result.colors.first?.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(result.profile?.id, 1)
    }

    func testTestConnectionSucceedsOnAny2xxWithoutDecoding() async throws {
        let client = makeClient { request in
            (.init(statusCode: 204, url: request.url!), Data())
        }

        _ = try await client.testConnection()
    }

    // MARK: - Authorization

    func testFetchColorsWithoutTokenOmitsAuthorizationHeader() async throws {
        let client = makeClient(noToken: true) { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (.init(statusCode: 200, url: request.url!), Self.colorsBody)
        }

        _ = try await client.fetchColors(printerProfileID: 1)
    }

    // MARK: - Failure mapping

    func testFetchColorsThrowsBadStatusOnServerError() async {
        let client = makeClient { request in
            (.init(statusCode: 500, url: request.url!), Data())
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    func testFetchColorsThrowsMalformedResponseOnUndecodableBody() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data(#"{"unexpected": true}"#.utf8))
        }

        await XCTAssertThrowsErrorAsync(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    // MARK: - Fixtures

    private static let printerProfilesBody = Data(
        """
        {"printer_profiles": [
          {"id": 1, "printer_make_model": "Example Printer", "paper_type": "Matte", "ink_type": "Pigment"},
          {"id": 4, "printer_make_model": null, "paper_type": null, "ink_type": null}
        ]}
        """.utf8
    )

    private static let colorsBody = Data(
        """
        {"colors": [{"id": 123, "name": "Red 12", "hex": "#C64A35",
            "rgb": {"r": 198, "g": 74, "b": 53},
            "responses": {"red": {"brightness": 0.87}}}],
         "printer_profile": {"id": 1, "printer_make_model": "Example Printer",
            "paper_type": "Matte", "ink_type": "Pigment"}}
        """.utf8
    )

    private func makeClient(
        noToken: Bool = false,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(
            baseURL: baseURL,
            token: noToken ? nil : "token-1",
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
