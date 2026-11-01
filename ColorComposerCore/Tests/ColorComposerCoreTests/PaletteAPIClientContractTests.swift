import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ColorComposerCore

/// Pins the `/api/v1` client behavior the generated-OpenAPI migration must
/// preserve (issue #39): endpoint paths, the `printer_profile_id` query,
/// bearer-token handling, error mapping, and envelope decoding. Whether the
/// client is migrated onto the generated transport or wraps it, these
/// observations have to keep holding.
final class PaletteAPIClientContractTests: XCTestCase {
    private static let printerProfilesBody = """
    {
      "printer_profiles": [
        {
          "id": 1,
          "printer_make_model": "Example Printer",
          "paper_type": "Matte",
          "ink_type": "Pigment"
        }
      ]
    }
    """.data(using: .utf8)!

    private static let colorsBody = """
    {
      "printer_profile": {
        "id": 1, "printer_make_model": "Epson", "paper_type": "Matte", "ink_type": "Dye"
      },
      "colors": [
        {
          "id": 123, "name": "Red 12", "hex": "#C64A35",
          "rgb": {"r": 198, "g": 74, "b": 53},
          "responses": {
            "red": {"brightness": 0.87},
            "lps": {"brightness": 0.52}
          }
        }
      ]
    }
    """.data(using: .utf8)!

    override func tearDown() {
        super.tearDown()
        PaletteAPITestSupportURLProtocol.handler = nil
    }

    func testFetchPrinterProfilesRequestsTheAPIv1EndpointWithJSONAccept() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.absoluteString, "http://example.com/api/v1/printer_profiles")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (PaletteAPITestSupportURLProtocol.response(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        let profiles = try await client.fetchPrinterProfiles()

        XCTAssertEqual(profiles.map(\.id), [1])
        XCTAssertEqual(profiles.first?.printerMakeModel, "Example Printer")
        XCTAssertEqual(profiles.first?.paperType, "Matte")
    }

    func testFetchColorsAppendsTheProfileIDQueryAndDecodesTheEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.absoluteString, "http://example.com/api/v1/colors?printer_profile_id=7")
            return (PaletteAPITestSupportURLProtocol.response(statusCode: 200, url: request.url!), Self.colorsBody)
        }

        let fetched = try await client.fetchColors(printerProfileID: 7)

        XCTAssertEqual(fetched.colors.map(\.id), [123])
        XCTAssertEqual(fetched.colors.first?.hex, "#C64A35")
        XCTAssertEqual(fetched.colors.first?.responses["red"]?.brightness, 0.87)
        XCTAssertEqual(fetched.colors.first?.responses["lps"]?.brightness, 0.52)
        XCTAssertNil(fetched.colors.first?.responses["green"])
        XCTAssertEqual(fetched.profile?.id, 1)
        XCTAssertEqual(fetched.profile?.inkType, "Dye")
    }

    func testBlankTokenSendsNoAuthorizationHeader() async throws {
        let client = makeClient(token: "   ") { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (PaletteAPITestSupportURLProtocol.response(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        _ = try await client.fetchPrinterProfiles()
    }

    func testNilTokenSendsNoAuthorizationHeader() async throws {
        let client = makeClient(token: nil) { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (PaletteAPITestSupportURLProtocol.response(statusCode: 200, url: request.url!), Self.printerProfilesBody)
        }

        _ = try await client.fetchPrinterProfiles()
    }

    func testServerErrorsSurfaceAsBadStatus() async {
        let client = makeClient { request in
            (PaletteAPITestSupportURLProtocol.response(statusCode: 503, url: request.url!), Data())
        }

        await assertAsyncThrows(try await client.fetchPrinterProfiles()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(503))
        }
    }

    func testUndecodableBodySurfacesAsMalformedResponse() async {
        let client = makeClient { request in
            (PaletteAPITestSupportURLProtocol.response(statusCode: 200, url: request.url!), Data("not json".utf8))
        }

        await assertAsyncThrows(try await client.fetchColors(printerProfileID: 1)) { error in
            XCTAssertEqual(error as? PaletteAPIError, .malformedResponse)
        }
    }

    func testTestConnectionSucceedsOnA2xxResponse() async throws {
        let client = makeClient { request in
            (PaletteAPITestSupportURLProtocol.response(statusCode: 204, url: request.url!), Data())
        }

        try await client.testConnection()
    }

    func testTestConnectionRejectsNon2xxResponses() async {
        let client = makeClient { request in
            (PaletteAPITestSupportURLProtocol.response(statusCode: 500, url: request.url!), Data())
        }

        await assertAsyncThrows(try await client.testConnection()) { error in
            XCTAssertEqual(error as? PaletteAPIError, .badStatus(500))
        }
    }

    private func makeClient(
        token: String? = nil,
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> PaletteAPIClient {
        PaletteAPITestSupportURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PaletteAPITestSupportURLProtocol.self]
        return PaletteAPIClient(
            baseURL: URL(string: "http://example.com")!,
            token: token,
            session: URLSession(configuration: configuration)
        )
    }
}
