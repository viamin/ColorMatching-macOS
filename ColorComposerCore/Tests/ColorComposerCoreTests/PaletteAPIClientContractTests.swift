import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Wire-contract tests pinning the exact `/api/v1` request and response
/// shapes `PaletteAPIClient` relies on. The migration to the generated
/// OpenAPI client (issue #39) must keep every behavior asserted here —
/// endpoints, query parameters, envelope decoding (snake_case), bearer-token
/// handling, and error mapping — so these tests are the migration's safety
/// net: they stay green exactly when the generated client reproduces the
/// hand-rolled client's observable behavior.
final class PaletteAPIClientContractTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        ContractMockURLProtocol.handler = nil
    }

    // MARK: - GET /api/v1/colors?printer_profile_id=N

    func testFetchColorsSendsProfileIDQueryAndDecodesEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer contract-token")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            XCTAssertEqual(components?.path, "/api/v1/colors")
            let query = components?.queryItems ?? []
            XCTAssertTrue(
                query.contains(URLQueryItem(name: "printer_profile_id", value: "7")),
                "colors endpoint is profile-scoped via printer_profile_id"
            )
            return (.init(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.colorsEnvelope)
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(fetched.colors.count, 1)
        let color = try XCTUnwrap(fetched.colors.first)
        XCTAssertEqual(color.id, 123)
        XCTAssertEqual(color.name, "Red 12")
        XCTAssertEqual(color.hex, "#C64A35")
        XCTAssertEqual(color.rgb?.r, 198)
        XCTAssertEqual(color.paletteID, 5)
        XCTAssertEqual(color.paletteName, "Default")
        XCTAssertEqual(color.sortOrder, 12)
        XCTAssertEqual(color.responses["red"]?.brightness ?? -1, 0.87, accuracy: 1e-9)
        XCTAssertEqual(color.responses["red"]?.source, "measurement")
        XCTAssertEqual(color.responses["lps"]?.apparentBrightness, 5)
        XCTAssertNil(color.responses["green"])
        XCTAssertNil(color.responses["blue"])
        XCTAssertNil(color.responses["white"])

        XCTAssertEqual(fetched.profile?.id, 3)
        XCTAssertEqual(fetched.profile?.printerMakeModel, "Epson")
        XCTAssertEqual(fetched.profile?.paperType, "Matte")
        XCTAssertEqual(fetched.profile?.inkType, "Dye")
    }

    func testFetchColorsAcceptsNullPrinterProfile() async throws {
        let client = makeClient { request in
            (.init(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             #"{"printer_profile":null,"colors":[{"id":1,"hex":"#112233","rgb":{"r":17,"g":34,"b":51},"responses":{"red":{"brightness":0.5}}}]}"#.data(using: .utf8)!)
        }

        let fetched = try await client.fetchColors(printerProfileID: 1)

        XCTAssertNil(fetched.profile)
        XCTAssertEqual(fetched.colors.first?.hex, "#112233")
    }

    func testFetchColorsThrowsMalformedResponseOnUndecodableBody() async {
        let client = makeClient { request in
            (.init(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("not json at all".utf8))
        }

        await assertAsyncThrows(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testFetchColorsThrowsBadStatusOnServerError() async {
        try await assertEachStatus([404, 500, 503]) { statusCode in
            let client = makeClient { request in
                (.init(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!, Data())
            }
            return try await client.fetchColors(printerProfileID: 7)
        }
    }

    // MARK: - GET /api/v1/printer_profiles

    func testFetchPrinterProfilesDecodesEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(
                request.url?.path, "/api/v1/printer_profiles",
                "profiles endpoint path"
            )
            return (.init(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.profilesEnvelope)
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles.first?.id, 1)
        XCTAssertEqual(profiles.first?.printerMakeModel, "Example Printer")
        XCTAssertEqual(profiles.last?.id, 2)
        XCTAssertNil(profiles.last?.paperType)
    }

    // MARK: - Connection test

    func testConnectionSucceedsOnAny2xx() async throws {
        let client = makeClient { request in
            (.init(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }

        try await client.testConnection()
    }

    func testConnectionThrowsUnauthorizedOn401() async {
        let client = makeClient { request in
            (.init(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }

        await assertAsyncThrows(try await client.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .unauthorized)
        }
    }

    func testConnectionThrowsBadStatusOnServiceUnavailable() async {
        let client = makeClient { request in
            (.init(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        }

        await assertAsyncThrows(try await client.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, PaletteAPIError.badStatus(503))
        }
    }

    // MARK: - Helpers

    private func makeClient(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        ContractMockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContractMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PaletteAPIClient(
            baseURL: URL(string: "http://example.com")!,
            token: "  contract-token  ",
            session: session
        )
    }

    private func assertAsyncThrows<T>(
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

    /// Runs `makeCall` once per status code, asserting `.badStatus(code)`.
    private func assertEachStatus<T>(
        _ statusCodes: [Int],
        file: StaticString = #filePath,
        line: UInt = #line,
        makeCall: (Int) async throws -> T
    ) async throws {
        for statusCode in statusCodes {
            do {
                _ = try await makeCall(statusCode)
                XCTFail("Expected .badStatus(\(statusCode))", file: file, line: line)
            } catch let error as PaletteAPIError {
                XCTAssertEqual(error, .badStatus(statusCode), file: file, line: line)
            }
        }
    }

    /// Envelope shaped exactly like the server's `GET /api/v1/colors`
    /// response (snake_case keys, nullable provenance fields).
    private static let colorsEnvelope = """
    {
      "printer_profile": {
        "id": 3,
        "printer_make_model": "Epson",
        "paper_type": "Matte",
        "ink_type": "Dye"
      },
      "colors": [
        {
          "id": 123,
          "name": "Red 12",
          "hex": "#C64A35",
          "rgb": {"r": 198, "g": 74, "b": 53},
          "palette_id": 5,
          "palette_name": "Default",
          "sort_order": 12,
          "responses": {
            "red": {"brightness": 0.87, "source": "measurement", "raw_value": null, "raw_unit": null, "apparent_brightness": null, "measured_at": null, "test_run_id": null},
            "lps": {"brightness": 0.52, "source": "response", "raw_value": null, "raw_unit": null, "apparent_brightness": 5, "measured_at": null, "test_run_id": null}
          }
        }
      ]
    }
    """.data(using: .utf8)!

    private static let profilesEnvelope = """
    {
      "printer_profiles": [
        {"id": 1, "printer_make_model": "Example Printer", "paper_type": "Matte", "ink_type": "Pigment"},
        {"id": 2, "printer_make_model": "Other Printer", "paper_type": null, "ink_type": null}
      ]
    }
    """.data(using: .utf8)!
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
