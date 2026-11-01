import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Behavioral contract `PaletteAPIClient` must keep satisfying when it is
/// migrated onto the generated OpenAPI client (issue #39): request shape,
/// bearer-token handling, error mapping, and wire decoding. Whatever backs
/// the client after the migration, these tests pin the observable behavior
/// the disk-cache/offline-fallback path depends on.
final class PaletteAPIClientMigrationTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MigrationMockURLProtocol.handler = nil
    }

    // MARK: - fetchColors

    func testFetchColorsSendsQueryAcceptAndBearerToken() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/colors")
            XCTAssertEqual(request.url?.query, "printer_profile_id=7")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
            return (.init(statusCode: 200, url: request.url!), Self.colorsEnvelope())
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(fetched.colors.count, 1)
        XCTAssertEqual(fetched.colors.first?.id, 10)
        XCTAssertEqual(fetched.profile?.id, 7)
        XCTAssertEqual(fetched.profile?.paperType, "Matte")
    }

    func testFetchColorsToleratesAbsentPrinterProfile() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsEnvelopeWithoutProfile())
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertNil(fetched.profile)
        XCTAssertEqual(fetched.colors.count, 1)
    }

    func testFetchColorsMapsServerErrorToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 500, url: request.url!), Data())
        }

        await assertThrowsPaletteAPIError(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error, .badStatus(500))
        }
    }

    func testFetchColorsMapsUnparseableBodyToMalformedResponse() async {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Data("<html>not json</html>".utf8))
        }

        await assertThrowsPaletteAPIError(try await client.fetchColors(printerProfileID: 7)) { error in
            XCTAssertEqual(error, .malformedResponse)
        }
    }

    // MARK: - fetchPrinterProfiles

    func testFetchPrinterProfilesDecodesSnakeCaseEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/v1/printer_profiles")
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesEnvelope())
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first, PrinterProfileDTO(
            id: 3,
            printerMakeModel: "Canon PRO-4100",
            paperType: "Glossy",
            inkType: "Dye"
        ))
    }

    // MARK: - Token handling

    func testAbsentTokenSendsNoAuthorizationHeader() async throws {
        let client = makeClient(token: nil) { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesEnvelope())
        }

        _ = try await client.fetchPrinterProfiles()
    }

    func testWhitespaceOnlyTokenSendsNoAuthorizationHeader() async throws {
        let client = makeClient(token: "   ") { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (.init(statusCode: 200, url: request.url!), Self.printerProfilesEnvelope())
        }

        _ = try await client.fetchPrinterProfiles()
    }

    // MARK: - testConnection

    func testTestConnectionSucceedsOnNoContent() async throws {
        let client = makeClient { request in
            (.init(statusCode: 204, url: request.url!), Data())
        }

        try await client.testConnection()
    }

    func testTestConnectionMapsUnavailableToBadStatus() async {
        let client = makeClient { request in
            (.init(statusCode: 503, url: request.url!), Data())
        }

        await assertThrowsPaletteAPIError(try await client.testConnection()) { error in
            XCTAssertEqual(error, .badStatus(503))
        }
    }

    // MARK: - Client-to-solver pipeline

    func testFetchedColorsConvertToSolverDomain() async throws {
        let client = makeClient { request in
            (.init(statusCode: 200, url: request.url!), Self.colorsEnvelope())
        }

        let domain = try await client.fetchColors(printerProfileID: 7).colors.compactMap { $0.toDomain() }

        XCTAssertEqual(domain.count, 1)
        let color = try XCTUnwrap(domain.first)
        XCTAssertEqual(color.brightness(for: .red), 0.25)
        XCTAssertNil(color.brightness(for: .white), "unmeasured conditions stay absent, never zero")
    }

    // MARK: - Fixtures

    private func makeClient(
        token: String? = "secret-token",
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        MigrationMockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MigrationMockURLProtocol.self]
        return PaletteAPIClient(
            baseURL: URL(string: "http://example.com")!,
            token: token,
            session: URLSession(configuration: configuration)
        )
    }

    private func assertThrowsPaletteAPIError<T>(
        _ expression: @autoclosure () async throws -> T,
        _ assertions: (PaletteAPIError) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected error to be thrown", file: file, line: line)
        } catch let error as PaletteAPIError {
            assertions(error)
        } catch {
            XCTFail("Expected PaletteAPIError, received \(error)", file: file, line: line)
        }
    }

    private static func colorsEnvelope() -> Data {
        """
        {
          "colors": [
            {
              "id": 10,
              "name": "Process Cyan",
              "hex": "#00FFFF",
              "rgb": {"r": 0, "g": 255, "b": 255},
              "palette_id": 2,
              "palette_name": "Process",
              "sort_order": 1,
              "responses": {
                "red": {"brightness": 0.25},
                "lps": {"brightness": 0.75, "source": "measurement"}
              }
            }
          ],
          "printer_profile": {
            "id": 7,
            "printer_make_model": "Epson P9000",
            "paper_type": "Matte",
            "ink_type": "Pigment"
          }
        }
        """.data(using: .utf8)!
    }

    private static func colorsEnvelopeWithoutProfile() -> Data {
        """
        {
          "colors": [
            {
              "id": 10,
              "name": "Process Cyan",
              "hex": "#00FFFF",
              "responses": {"red": {"brightness": 0.25}}
            }
          ]
        }
        """.data(using: .utf8)!
    }

    private static func printerProfilesEnvelope() -> Data {
        """
        {
          "printer_profiles": [
            {
              "id": 3,
              "printer_make_model": "Canon PRO-4100",
              "paper_type": "Glossy",
              "ink_type": "Dye"
            }
          ]
        }
        """.data(using: .utf8)!
    }
}

private final class MigrationMockURLProtocol: URLProtocol, @unchecked Sendable {
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
